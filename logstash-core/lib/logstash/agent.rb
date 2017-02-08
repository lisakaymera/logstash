# encoding: utf-8
require "logstash/environment"
require "logstash/errors"
require "logstash/config/cpu_core_strategy"
require "logstash/instrument/collector"
require "logstash/instrument/metric"
require "logstash/instrument/periodic_pollers"
require "logstash/instrument/collector"
require "logstash/instrument/metric"
require "logstash/pipeline"
require "logstash/webserver"
require "logstash/event_dispatcher"
require "logstash/config/source_loader"
require "logstash/pipeline_action"
require "logstash/converge_result"
require "logstash/state_resolver"
require "stud/trap"
require "uri"
require "socket"
require "securerandom"

LogStash::Environment.load_locale!

class LogStash::Agent
  include LogStash::Util::Loggable
  STARTED_AT = Time.now.freeze

  attr_reader :metric, :name, :pipelines, :settings, :webserver, :dispatcher
  attr_accessor :logger

  # initialize method for LogStash::Agent
  # @param params [Hash] potential parameters are:
  #   :name [String] - identifier for the agent
  #   :auto_reload [Boolean] - enable reloading of pipelines
  #   :reload_interval [Integer] - reload pipelines every X seconds
  def initialize(settings = LogStash::SETTINGS, source_loader = nil)
    @logger = self.class.logger
    @settings = settings
    @auto_reload = setting("config.reload.automatic")

    @pipelines = {}
    @name = setting("node.name")
    @http_host = setting("http.host")
    @http_port = setting("http.port")
    @http_environment = setting("http.environment")
    # Generate / load the persistent uuid
    id

    @source_loader = source_loader.nil? ? LogStash::Config::SOURCE_LOADER.create(settings) : source_loader

    @reload_interval = setting("config.reload.interval")
    @pipelines_mutex = Mutex.new

    @collect_metric = setting("metric.collect")

    # Create the collectors and configured it with the library
    configure_metrics_collectors

    @state_resolver = LogStash::StateResolver.new(metric)

    @pipeline_reload_metric = metric.namespace([:stats, :pipelines])
    @instance_reload_metric = metric.namespace([:stats, :reloads])
    initialize_agent_metrics

    @dispatcher = LogStash::EventDispatcher.new(self)
    LogStash::PLUGIN_REGISTRY.hooks.register_emitter(self.class, dispatcher)
    dispatcher.fire(:after_initialize)
  end

  def execute
    @thread = Thread.current # this var is implicilty used by Stud.stop?
    logger.debug("starting agent")

    start_webserver
    converge_state_and_update

    if @auto_reload
      # `sleep_then_run` instead of firing the interval right away
      Stud.interval(@reload_interval, :sleep_then_run => true) { converge_state_and_update }
    else
      # If we don't have any pipelines at this point we assume that the current logstash
      # config is bad and all of the pipeline died.
      #
      # We assume that we cannot recover from that scenario and quit logstash
      return 1 if clean_state?

      while !Stud.stop?
        if clean_state? || running_pipelines?
          sleep 0.5
        else
          break
        end
      end
    end
  end

  def converge_state_and_update
    pipeline_configs = @source_loader.fetch

    # TODO(ph) did we get the pipeline succesfully or not
    # if the fetch fails we should log it but not reload the state


    # We Lock any access on the pipelines, since the actions will modify the
    # content of it.
    converge_result = nil

    @pipelines_mutex.synchronize do
      pipeline_actions = resolve_actions(pipeline_configs)
      converge_result = converge_state(pipeline_actions)
    end

    report_currently_running_pipelines
    update_metrics(converge_result)
  end

  # Calculate the Logstash uptime in milliseconds
  #
  # @return [Fixnum] Uptime in milliseconds
  def uptime
    ((Time.now.to_f - STARTED_AT.to_f) * 1000.0).to_i
  end

  def shutdown
    stop_collecting_metrics
    stop_webserver
    shutdown_pipelines
  end

  def id
    return @id if @id

    uuid = nil
    if ::File.exists?(id_path)
      begin
        uuid = ::File.open(id_path) {|f| f.each_line.first.chomp }
      rescue => e
        logger.warn("Could not open persistent UUID file!",
                    :path => id_path,
                    :error => e.message,
                    :class => e.class.name)
      end
    end

    if !uuid
      uuid = SecureRandom.uuid
      logger.info("No persistent UUID file found. Generating new UUID",
                  :uuid => uuid,
                  :path => id_path)
      begin
        ::File.open(id_path, 'w') {|f| f.write(uuid) }
      rescue => e
        logger.warn("Could not write persistent UUID file! Will use ephemeral UUID",
                    :uuid => uuid,
                    :path => id_path,
                    :error => e.message,
                    :class => e.class.name)
      end
    end

    @id = uuid
  end

  def get_pipeline(pipeline_id)
    @pipelines_mutex.synchronize do
      @pipelines[:pipeline_id]
    end
  end

  def running_pipelines
    @pipelines_mutex.synchronize do
      @pipelines.select {|pipeline_id, _| running_pipeline?(pipeline_id) }
    end
  end

  def running_pipelines?
    @pipelines_mutex.synchronize do
      @pipelines.select {|pipeline_id, _| running_pipeline?(pipeline_id) }.any?
    end
  end

  def close_pipeline(id)
    pipeline = @pipelines[id]
    if pipeline
      @logger.warn("closing pipeline", :id => id)
      pipeline.close
    end
  end

  def close_pipelines
    @pipelines.each  do |id, _|
      close_pipeline(id)
    end
  end

  private
  def id_path
    @id_path ||= ::File.join(settings.get("path.data"), "uuid")
  end

  # We depends on a series of task derived from the internal state and what
  # need to be run, theses actions are applied to the current pipelines to converge to
  # the desired state.
  #
  # The current actions are simple and favor composition, allowing us to experiment with different
  # way to making them and also test them in isolation with the current running agent.
  #
  # Currently only action related to pipeline exist, but nothing prevent us to use the same logic
  # for other tasks.
  def converge_state(pipeline_actions)
    logger.info("Converging pipelines")

    converge_result = LogStash::ConvergeResult.new(pipeline_actions.size)

    logger.info("Needed actions to converge", :actions_count => pipeline_actions.size) unless pipeline_actions.empty?

    pipeline_actions.each do |action|
      # We execute every task we need to converge the current state of pipelines
      # for every task we will record the action result, that will help us
      # the results of all the task will determine if the converge was successful or not
      #
      # The ConvergeResult#add, will accept the following values
      #  - boolean
      #  - FailedAction
      #  - SuccessfulAction
      #  - Exception
      #
      # This give us a bit more extensibility with the current startup/validation model
      # that we currently have.
      begin
        logger.info("Executing action", :action => action)
        action_result = action.execute(@pipelines)
        converge_result.add(action, action_result)
      rescue Exception => e
        logger.error("Failed to execute action", :action => action, :exception => e.class.name, :message => e.message)
        converge_result.add(action, e)
      end

      converge_result
    end
  end

  def resolve_actions(pipeline_configs)
    @state_resolver.resolve(@pipelines, pipeline_configs)
  end

  def report_currently_running_pipelines
    number_of_running_pipeline = running_pipelines.size

    if number_of_running_pipeline.size > 0
      logger.info("Pipelines running", :count => number_of_running_pipeline, :pipelines => running_pipelines.values.collect(&:pipeline_id) )
    else
      logger.info("No pipeline are currently running")
    end
  end

  def start_webserver
    options = {:http_host => @http_host, :http_ports => @http_port, :http_environment => @http_environment }
    @webserver = LogStash::WebServer.new(@logger, self, options)
    Thread.new(@webserver) do |webserver|
      LogStash::Util.set_thread_name("Api Webserver")
      webserver.run
    end
  end

  def stop_webserver
    @webserver.stop if @webserver
  end

  def configure_metrics_collectors
    @collector = LogStash::Instrument::Collector.new

    @metric = if collect_metrics?
      @logger.debug("Agent: Configuring metric collection")
      LogStash::Instrument::Metric.new(@collector)
    else
      LogStash::Instrument::NullMetric.new(@collector)
    end

    @periodic_pollers = LogStash::Instrument::PeriodicPollers.new(@metric, settings.get("queue.type"), self)
    @periodic_pollers.start
  end

  def stop_collecting_metrics
    @periodic_pollers.stop
  end

  def collect_metrics?
    @collect_metric
  end

  def shutdown_pipelines
    # In this context I could just call shutdown, but I've decided to
    # use the stop action implementation for that so we have the same code.
    @pipelines_mutex.synchronize do
      @pipelines.keys.each { |pipeline_id| LogStash::PipelineAction::Stop.new(pipeline_id).execute(@pipelines) }
    end
  end

  def running_pipeline?(pipeline_id)
    thread = @pipelines[pipeline_id].thread
    thread.is_a?(Thread) && thread.alive?
  end

  def clean_state?
    @pipelines.empty?
  end

  def setting(key)
    @settings.get(key)
  end

  # Methods related to the creation of all metrics
  # related to states changes and failures
  #
  # I think we could use an observer here to decouple the metrics, but moving the code
  # into separate function is the first step we take.
  def update_metrics(converge_result)
    converge_result.failed_actions.each do |action, action_result|
      update_failures_metrics(action, action_result)
    end

    converge_result.successful_actions.each do |action, action_result|
      update_success_metrics(action, action_result)
    end
  end

  def update_success_metrics(action, action_result)
    case action
      when LogStash::PipelineAction::Create
        # When a pipeline is successfully created we create the metric
        # place holder related to the lifecycle of the pipeline
        initialize_pipeline_metrics(action)
      when LogStash::PipelineAction::Reload
        update_successful_reload_metrics(action, action_result)
    end
  end

  def update_failures_metrics(action, action_result)
    @instance_reload_metric.increment(:failures)

    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:failures)
      # TODO(ph): I am not sure we should expose the backtrace in the API
      n.gauge(:last_error, { :message => action_result.message, :backtrace => action_result.backtrace})
      n.gauge(:last_failure_timestamp, LogStash::Timestamp.now)
    end
  end

  def initialize_agent_metrics
    @instance_reload_metric.increment(:successes, 0)
    @instance_reload_metric.increment(:failures, 0)
  end

  def initialize_pipeline_metrics(action)
    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:successes, 0)
      n.increment(:failures, 0)
      n.gauge(:last_error, nil)
      n.gauge(:last_success_timestamp, nil)
      n.gauge(:last_failure_timestamp, nil)
    end
  end

  def update_successful_reload_metrics(action, action_result)
    @instance_reload_metric.increment(:successes)

    @pipeline_reload_metric.namespace([action.pipeline_id, :reloads]).tap do |n|
      n.increment(:successes)
      n.gauge(:last_success_timestamp, action_result.executed_at)
    end
  end
end # class LogStash::Agent

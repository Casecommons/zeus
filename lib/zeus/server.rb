require 'json'
require 'socket'
require 'forwardable'

module Zeus
  class Server
    extend Forwardable

    autoload :Stage,                       'zeus/server/stage'
    autoload :Acceptor,                    'zeus/server/acceptor'
    autoload :FileMonitor,                 'zeus/server/file_monitor'
    autoload :LoadTracking,                'zeus/server/load_tracking'
    autoload :ForkedProcess,               'zeus/server/forked_process'
    autoload :ClientHandler,               'zeus/server/client_handler'
    autoload :ProcessTreeMonitor,          'zeus/server/process_tree_monitor'
    autoload :ProcessTreeRenderer,         'zeus/server/process_tree_renderer'
    autoload :AcceptorRegistrationMonitor, 'zeus/server/acceptor_registration_monitor'

    def self.define!(&b)
      @@definition = Zeus::DSL::Evaluator.new.instance_eval(&b)
    end

    def self.acceptors
      defined?(@@definition) ? @@definition.acceptors : []
    end

    def initialize
      @file_monitor                  = FileMonitor::FSEvent.new(&method(:dependency_did_change))
      @acceptor_registration_monitor = AcceptorRegistrationMonitor.new
      @process_tree_monitor          = ProcessTreeMonitor.new(@file_monitor, @@definition)
      @client_handler                = ClientHandler.new(acceptor_commands, self)

      set_mode
      start_renderer if visual_mode?

      @plan = @@definition.to_process_object(self)
    end

    def set_mode
      @mode = $stdout.isatty ? :visual : :text
    end

    def visual_mode?
      @mode == :visual
    end

    def text_mode?
      @mode == :text
    end

    def start_renderer
      @renderer = ProcessTreeRenderer.new(@@definition)
      @renderer.run!
    end

    def dependency_did_change(file)
      @process_tree_monitor.kill_nodes_with_feature(file)
    end

    def monitors
      [@file_monitor, @process_tree_monitor, @acceptor_registration_monitor, @client_handler]
    end

    def run
      $0 = "zeus master"
      trap("TERM") { exit 0 }
      trap("INT") {
        exit 0
      }

      LoadTracking.inject!(self)

      @plan.run(true) # boot the actual app
      monitors.each(&:close_child_socket)

      runloop!
    ensure
      File.unlink(Zeus::SOCKET_NAME)
    end

    # this is used in conjunction with Zeus::LoadTracking to track files loaded
    # using `load` rather than `require`.
    def add_extra_feature(full_expanded_path)
      @extra_loaded_features ||= []
      @extra_loaded_features << full_expanded_path
    end

    def extra_features
      @extra_loaded_features || []
    end

    # Child process API
    def __CHILD__close_parent_sockets
      monitors.each(&:close_parent_socket)
    end

    def_delegators :@acceptor_registration_monitor,
      :__CHILD__register_acceptor,
      :__CHILD__find_acceptor_for_command

    def_delegators :@process_tree_monitor,
      :__CHILD__stage_starting_with_pid,
      :__CHILD__stage_has_feature

    private

    def acceptor_commands
      self.class.acceptors.map(&:commands).flatten
    end

    def runloop!
      loop do
        ready, = IO.select(monitors.map(&:datasource), [], [], 1)
        next unless ready
        monitors.each do |m|
          m.on_datasource_event if ready.include?(m.datasource)
        end
      end
    end

  end
end

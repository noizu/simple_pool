defmodule Noizu.SimplePool.ServerBehaviour do
  alias Noizu.SimplePool.OptionSettings
  alias Noizu.SimplePool.OptionValue
  alias Noizu.SimplePool.OptionList
  # @TODO auto generate convience methods, fetch worker_entity_provider\s set of methods using reflection. and use macros to genrate.

  # @TODO
  # 1. automaticly pass calling context as part of s_cast/s_call,
  # 2. Call tuples should look as follows  {{:call, params, ...}, context}
  # 3. Support module lookup of server processes using s_call or self_call
  # 4. Support module worker migration.
  # 5. Test and fin!

  @callback option_settings() :: Map.t
  @callback start_link(any) :: any
  #@callback start_children(any) :: any

  # TODO callbacks


  @methods([:start_link, :init, :terminate, :load, :status, :worker_pid!, :worker_ref!, :worker_clear!, :worker_deregister!, :worker_register!, :worker_load!, :worker_migrate!, :worker_remove!, :worker_add!])
  @features([:auto_identifier, :lazy_load, :asynch_load, :inactivity_check, :s_redirect, :s_redirect_handle, :ref_lookup_cache])
  @default_features([:lazy_load, :s_redirect, :s_redirect_handle, :inactivity_check])

  def prepare_options(options) do
    settings = %OptionSettings{
      option_settings: %{
        features: %OptionList{option: :features, default: Application.get_env(Noizu.SimplePool, :default_features, @default_features), valid_members: @features, membership_set: false},
        only: %OptionList{option: :only, default: @methods, valid_members: @methods, membership_set: true},
        override: %OptionList{option: :override, default: [], valid_members: @methods, membership_set: true},
        verbose: %OptionValue{option: :verbose, default: Application.get_env(Noizu.SimplePool, :verbose, false)},
        worker_state_entity: %OptionValue{option: :worker_state_entity, default: :auto},
        server_driver: %OptionValue{option: :server_driver, default: Application.get_env(Noizu.SimplePool, :default_server_driver, Noizu.SimplePool.ServerDriver.Default)},
        worker_lookup_handler: %OptionValue{option: :worker_lookup_handler, default: Application.get_env(Noizu.SimplePool, :worker_lookup_handler, Noizu.SimplePool.WorkerLookupBehaviour.DefaultImplementation)},
        server_provider: %OptionValue{option: :server_provider, default: Application.get_env(Noizu.SimplePool, :default_server_provider, Noizu.SimplePool.Server.ProviderBehaviour.Default)}
      }
    }

    initial = OptionSettings.expand(settings, options)
    modifications = Map.put(initial.effective_options, :required, List.foldl(@methods, %{}, fn(x, acc) -> Map.put(acc, x, initial.effective_options.only[x] && !initial.effective_options.override[x]) end))
    %OptionSettings{initial| effective_options: Map.merge(initial.effective_options, modifications)}
  end

  defmacro __using__(options) do
    option_settings = prepare_options(options)
    options = option_settings.effective_options
    required = options.required
    verbose = options.verbose
    worker_lookup_handler = options.worker_lookup_handler

    case Map.keys(option_settings.output.errors) do
      [] -> :ok
      l when is_list(l) ->
        IO.puts "
    ---------------------- Errors In Pool Settings  ----------------------------
    #{inspect option_settings, pretty: true, limit: :infinity}
    ----------------------------------------------------------------------------
        "
    end

    features = MapSet.new(options.features)
    quote do
      require Logger
      import unquote(__MODULE__)
      @behaviour Noizu.SimplePool.ServerBehaviour
      @base(Module.split(__MODULE__) |> Enum.slice(0..-2) |> Module.concat)

      @worker(Module.concat([@base, "Worker"]))
      @worker_supervisor(Module.concat([@base, "WorkerSupervisor"]))
      @server(__MODULE__)
      @pool_supervisor(Module.concat([@base, "PoolSupervisor"]))
      @simple_pool_group({@base, @worker, @worker_supervisor, __MODULE__, @pool_supervisor})

      @worker_state_entity(Noizu.SimplePool.Behaviour.expand_worker_state_entity(@base, unquote(options.worker_state_entity)))
      @server_provider(unquote(options.server_provider))
      @worker_lookup_handler(unquote(worker_lookup_handler))
      @module_and_lookup_handler({__MODULE__, @worker_lookup_handler})

      def worker_state_entity, do: @worker_state_entity
      def option_settings, do: unquote(Macro.escape(option_settings))


      #=========================================================================
      # Genserver Lifecycle
      #=========================================================================
      if unquote(required.start_link) do
        def start_link(sup) do
          if unquote(verbose) do
            @base.banner("START_LINK #{__MODULE__} (#{inspect sup})") |> Logger.info()
          end
          GenServer.start_link(__MODULE__, sup, name: __MODULE__)
        end
      end # end start_link

      if (unquote(required.init)) do
        def init(sup) do
          if unquote(verbose) do
            @base.banner("INIT #{__MODULE__} (#{inspect sup})") |> Logger.info()
          end
          @server_provider.init(__MODULE__, sup)
        end
      end # end init

      if (unquote(required.terminate)) do
        def terminate(reason, state), do: @server_provider.terminate(reason, state)
      end # end terminate

      def disable_server(elixir_node) do
        @worker_lookup_handler.disable_server!(@base, elixir_node)
      end


      def worker_sup_start(ref, sup, context) do
        childSpec = @worker_supervisor.child(ref, context)
        case Supervisor.start_child(sup, childSpec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end # end case
      end # endstart/3

      def worker_sup_remove(ref, sup, _context) do
        Supervisor.terminate_child(sup, ref)
        Supervisor.delete_child(sup, ref)
      end # end remove/3

      #=========================================================================
      #
      #=========================================================================
      def worker_lookup_handler(), do: @worker_lookup_handler
      def base(), do: @base
      #-------------------------------------------------------------------------------
      # Startup: Lazy Loading/Asynch Load/Immediate Load strategies. Blocking/Lazy Initialization, Loading Strategy.
      #-------------------------------------------------------------------------------
      if unquote(required.status) do
        def status(context \\ nil), do: @server_provider.status(__MODULE__, context)
      end

      if unquote(required.load) do
        def load(options \\ nil, context \\ nil), do: @server_provider.load(__MODULE__, options, context)
      end

      #-------------------------------------------------------------------------------
      # Worker Process Management
      #-------------------------------------------------------------------------------
      if unquote(required.worker_add!) do
        def worker_add!(ref, options \\ nil, context \\ nil), do: internal_call({:worker_add!, ref, options}, context)
      end

      if unquote(required.worker_remove!) do
        def worker_remove!(ref, options \\ nil, context \\ nil), do: internal_cast({:worker_remove!, ref, options}, context)
      end

      if unquote(required.worker_migrate!) do
        def worker_migrate!(ref, rebase, options \\ nil, context \\ nil), do: {:error, :future_work}
      end

      if unquote(required.worker_load!) do
        def worker_load!(ref, options \\ nil, context \\ nil), do: s_cast!(ref, {:load, options}, context)
      end

      if unquote(required.worker_register!) do
        def worker_register!(ref, process_node, context \\ nil), do: @worker_lookup_handler.reg_worker!(@base, ref, process_node, context)
      end

      if unquote(required.worker_deregister!) do
        def worker_deregister!(ref, context \\ nil), do: @worker_lookup_handler.dereg_worker!(@base, ref, context)
      end

      if unquote(required.worker_clear!) do
        def worker_clear!(ref, process_node, context \\ nil), do: @worker_lookup_handler.clear_process!(@base, ref, process_node, context)
      end

      if unquote(required.worker_ref!) do
        def worker_ref!(identifier, _context \\ nil), do: @worker_state_entity.ref(identifier)
      end

      if unquote(required.worker_pid!) do
        def worker_pid!(ref, options \\ [], context \\ nil) do
          case @worker_lookup_handler.get_reg_worker!(@base, ref) do
            {false, :nil} ->
              if options[:spawn] do
                worker_add!(ref, options, context)
              else
                {:error, :not_registered}
              end
            {true, pid} -> {:ok, pid}
            {:error, error} -> {:error, error}
          end
        end
      end

      #-------------------------------------------------------------------------------
      # Internal Forwarding
      #-------------------------------------------------------------------------------
      def handle_call({:i, call, context}, from, state), do: @server_provider.internal_call_handler(call, context, state, from)
      def handle_cast({:i, call, context}, state), do: @server_provider.internal_cast_handler(call, context, state)
      def handle_info({:i, call, context}, state), do: @server_provider.internal_info_handler(call, context, state)

      @doc """
        Forward a call to the appropriate GenServer instance for this __MODULE__.
        @TODO add support for directing calls to specific nodes for load balancing purposes.
        @TODO add support for s_redirect
      """
      def self_call(call, context \\ nil, timeout \\ 15_000) do
        extended_call = {:s, call, context}
        GenServer.call(__MODULE__, extended_call, timeout)
      end
      def self_cast(call, context \\ nil, timeout \\ 15_000) do
        extended_call = {:s, call, context}
        GenServer.call(__MODULE__, extended_call, timeout)
      end

      def internal_call(call, context \\ nil, timeout \\ 15_000) do
        extended_call = {:i, call, context}
        GenServer.call(__MODULE__, extended_call, timeout)
      end
      def internal_cast(call, context \\ nil) do
        extended_call = {:i, call, context}
        GenServer.cast(__MODULE__, extended_call)
      end

      #-------------------------------------------------------------------------------
      #
      #-------------------------------------------------------------------------------
      def fetch(identifier, options \\ :default, context \\ nil), do: s_call(identifier, {:fetch, options}, context)

      #-------------------------------------------------------------------------
      # s_redirect
      #-------------------------------------------------------------------------
      if unquote(MapSet.member?(features, :s_redirect)) || unquote(MapSet.member?(features, :s_redirect_handle)) do
        def handle_cast({_type, {__MODULE__, _ref}, call}, state), do: handle_cast(call, state)
        def handle_call({_type, {__MODULE__, _ref}, call}, from, state), do: handle_call(call, from, state)

        def handle_cast({:s_cast, {call_server, ref}, {:s, _inner, context} = call}, state) do
          call_server.worker_clear!(ref, {self(), node()}, context)
          call_server.s_cast(ref, call)
          {:noreply, state}
        end # end handle_cast/:s_cast

        def handle_cast({:s_cast!, {call_server, ref}, {:s, _inner, context} = call}, state) do
          call_server.worker_clear!(ref, {self(), node()}, context)
          call_server.s_cast!(ref, call)
          {:noreply, state}
        end # end handle_cast/:s_cast!

        def handle_call({:s_call, {call_server, ref, timeout}, {:s, _inner, context} = call}, from, state) do
          call_server.worker_clear!(ref, {self(), node()}, context)
          {:reply, :s_retry, state}
        end # end handle_call/:s_call

        def handle_call({:s_call!, {call_server, ref, timeout}, {:s, _inner, context}} = call, from, state) do
          call_server.worker_clear!(ref, {self(), node()}, context)
          {:reply, :s_retry, state}
        end # end handle_call/:s_call!
      end # if feature.s_redirect

      #-------------------------------------------------------------------------
      # s_call unsafe implementations
      #-------------------------------------------------------------------------
      def s_call_unsafe(ref, spawn, extended_call, context, timeout \\ 15_000) do
        case worker_pid!(ref, spawn, context) do
          {:ok, pid} ->
            case GenServer.call(pid, extended_call, timeout) do
              :s_retry ->
                case worker_pid!(ref, spawn, context) do
                  {:ok, pid} -> GenServer.call(pid, extended_call, timeout)
                  error -> error
                end
              v -> v
            end
          error -> error
        end # end case
      end #end s_call_unsafe

      def s_cast_unsafe(ref, spawn, extended_call, context) do
        case worker_pid!(ref, spawn, context) do
          {:ok, pid} -> GenServer.cast(pid, extended_call)
          error -> error
        end
      end

      if unquote(MapSet.member?(features, :crash_protection)) do
        @doc """
          Forward a call to appopriate worker, along with delivery redirect details if s_redirect enabled. Spawn worker if not currently active.
        """
        def s_call!(identifier, call, context \\ nil, timeout \\ 15_000) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_call!, {__MODULE__, ref, timeout}, {:s, call, context}}, else: {:s, call, context}
              try do
                s_call_unsafe(ref, [spawn: true], extended_call, context, timeout)
              catch
                :exit, e ->
                  try do
                    Logger.warn @base.banner("#{__MODULE__} - dead worker (#{inspect ref})")
                    worker_deregister!(ref, context)
                    s_call_unsafe(ref, [spawn: true], extended_call, context, timeout)
                  catch
                    :exit, e ->
                      {:error, {:exit, e}}
                  end # end inner try
              end # end try
          end
        end # end s_call!

        @doc """
          Forward a cast to appopriate worker, along with delivery redirect details if s_redirect enabled. Spawn worker if not currently active.
        """
        def s_cast!(identifier, call, context \\ nil) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_cast!, {__MODULE__, ref}, {:s, call, context}}, else: {:s, call, context}
              try do
                s_cast_unsafe(ref, [spawn: true], extended_call, context)
              catch
                :exit, e ->
                  try do
                    Logger.warn @base.banner("#{__MODULE__} - dead worker (#{inspect ref})")
                    worker_deregister!(ref, context)
                    s_cast_unsafe(ref, [spawn: true], extended_call, context)
                  catch
                    :exit, e ->
                      {:error, {:exit, e}}
                  end # end inner try
              end # end try
          end # end case worker_ref!
        end # end s_cast!

        @doc """
          Forward a call to appopriate worker, along with delivery redirect details if s_redirect enabled. Do not spawn worker if not currently active.
        """
        def s_call(identifier, call, context \\ nil, timeout \\ 15_000) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_call, {__MODULE__, ref, timeout}, {:s, call, context}}, else: {:s, call, context}
              try do
                s_call_unsafe(ref, [spawn: false], extended_call, context, timeout)
              catch
                :exit, e ->
                  try do
                    Logger.warn @base.banner("#{__MODULE__} - dead worker (#{inspect ref})")
                    worker_deregister!(ref, context)
                    s_call_unsafe(ref, [spawn: false], extended_call, context, timeout)
                  catch
                    :exit, e ->
                      {:error, {:exit, e}}
                  end # end inner try
              end # end try
          end # end case
        end # end s_call!

        @doc """
          Forward a cast to appopriate worker, along with delivery redirect details if s_redirect enabled. Do not spawn worker if not currently active.
        """
        def s_cast(identifier, call, context \\ nil) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_cast, {__MODULE__, ref}, {:s, call, context}}, else: {:s, call, context}
              try do
                s_cast_unsafe(ref, [spawn: false], extended_call, context)
              catch
                :exit, e ->
                  try do
                    Logger.warn @base.banner("#{__MODULE__} - dead worker (#{inspect ref})")
                    worker_deregister!(ref, context)
                    s_cast_unsafe(ref, [spawn: false], extended_call, context)
                  catch
                    :exit, e ->
                      {:error, {:exit, e}}
                  end # end inner try
              end # end try
          end # end case worker_ref!
        end # end s_cast!

      else # no crash_protection


        @doc """
          Forward a call to appopriate worker, along with delivery redirect details if s_redirect enabled. Spawn worker if not currently active.
        """
        def s_call!(identifier, call, context \\ nil, timeout \\ 15_000) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_call!, {__MODULE__, ref, timeout}, {:s, call, context}}, else: {:s, call, context}
              s_call_unsafe(ref, [spawn: true], extended_call, context, timeout)
          end
        end # end s_call!

        @doc """
          Forward a cast to appopriate worker, along with delivery redirect details if s_redirect enabled. Spawn worker if not currently active.
        """
        def s_cast!(identifier, call, context \\ nil) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_cast!, {__MODULE__, ref}, {:s, call, context}}, else: {:s, call, context}
              s_cast_unsafe(ref, [spawn: true], extended_call, context)
          end # end case worker_ref!
        end # end s_cast!

        @doc """
          Forward a call to appopriate worker, along with delivery redirect details if s_redirect enabled. Do not spawn worker if not currently active.
        """
        def s_call(identifier, call, context \\ nil, timeout \\ 15_000) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_call, {__MODULE__, ref, timeout}, {:s, call, context}}, else: {:s, call, context}
              s_call_unsafe(ref, [spawn: false], extended_call, context, timeout)
          end # end case
        end # end s_call!

        @doc """
          Forward a cast to appopriate worker, along with delivery redirect details if s_redirect enabled. Do not spawn worker if not currently active.
        """
        def s_cast(identifier, call, context \\ nil) do
          case  worker_ref!(identifier, context) do
            {:error, details} -> {:error, details}
            ref ->
              extended_call = if unquote(MapSet.member?(features, :s_redirect)), do: {:s_cast, {__MODULE__, ref}, {:s, call, context}}, else: {:s, call, context}
              s_cast_unsafe(ref, [spawn: false], extended_call, context)
          end # end case worker_ref!
        end # end s_cast!
      end # end if feature.crash_protection
    end # end quote
  end #end __using__
end

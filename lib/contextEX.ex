defmodule ContextEX do
  @top_agent_name :ContextEXAgent
  @node_agent_prefix "_node_agent_"
  @local_node_agent_prefix "_local_node_agent_"
  @sink_node_group_name :sink

  @partial_prefix "_partial_"
  @arg_name "arg"


  defmacro __using__(_options) do
    quote do
      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
      Module.register_attribute __MODULE__, :layered_function, accumulate: true, persist: false
      Module.register_attribute __MODULE__, :layered_private_function, accumulate: true, persist: false

      defp get_activelayers(), do: get_activelayers(self())
      defp cast_activate_layer(map), do: cast_activate_layer(self(), map)
      defp get_active_local_layers(), do: get_active_local_layers(self())
      defp cast_activate_local_layer(map), do: cast_activate_local_layer(self(), map)
      defp call_activate_local_layer(map), do: cast_activate_local_layer(self(), map)
      defp call_activate_layer(map), do: call_activate_layer(self(), map)
      defp is_active?(layer), do: is_active?(self(), layer)
    end
  end

  defmacro __before_compile__(env) do
    attrs = Module.get_attribute(env.module, :layered_function)
    defList1 = attrs |> Enum.map(&(gen_genericfunction_ast(&1, env.module)))

    attrs = Module.get_attribute(env.module, :layered_private_function)
    defList2 = attrs |> Enum.map(&(gen_private_genericfunction_ast(&1, env.module)))

    # return AST
    {:__block__, [], defList1 ++ defList2}
  end

  @doc """
  Start global contextServer.
  This server contains list which is pid of nodeLevel contexteServers.
  """
  def start() do
    unless (is_pid :global.whereis_name(@top_agent_name)) do
      try do
        Agent.start(fn -> {nil, []} end, [name: {:global, @top_agent_name}])
      rescue
        e -> e
      end
    end
  end

  @doc """
  get top agent pid until sink node register top agent with global
  """
  def get_top_agent_pid() do
    pid = :global.whereis_name(unquote(@top_agent_name))
    if(pid == :undefined) do
      :timer.sleep(100)
      get_top_agent_pid()
    else
      pid
    end
  end

  @doc """
  Register process(self()) in nodeLevel contextServer.
  """
  defmacro init_context(group \\ nil) do
    quote do
      with  self_pid = self(),
        top_agent_pid = get_top_agent_pid(),
        node_agent_name = String.to_atom(unquote(@node_agent_prefix) <> Atom.to_string(node())),
        local_node_agent_name = String.to_atom(unquote(@local_node_agent_prefix) <> Atom.to_string(node())),
        sink_node_group_name = unquote(@sink_node_group_name),
        group = (if (unquote(group) == nil), do: nil, else: unquote(group))
        # ↓じゃtestのunregisterで怒られる
        # group = unquote(group)
      do
        group = if (is_list(group) && Enum.all?(group, fn x -> is_atom(x) end)) do
          group
        else
          if(is_atom(group)) do
            [group]
          else
            raise ArgumentError, message: "group must be atom or atom list."
          end
        end
        node_agent_pid =
          case Process.whereis(node_agent_name) do
            # unregistered
            nil ->
              case Agent.start(fn -> [] end, [name: node_agent_name]) do
                {:ok, pid} -> pid
                {:error, {:already_started, pid}} -> pid
                _ -> raise "Error at init_context!"
              end
            # already registered
            pid -> pid
          end

        local_node_agent_pid =
          case Process.whereis(local_node_agent_name) do
            #unregistered
            nil ->
              case Agent.start(fn -> [] end, [name: local_node_agent_name]) do
                {:ok, pid} -> pid
                {:error, {:already_started, pid}} -> pid
                _ -> raise "Error at init_context!"
              end
              # already registered
            pid -> pid
          end

        # register self_pid in node_agent
        Agent.update(node_agent_pid, fn(state) ->
          [{group, self_pid, %{}} | state]
        end)

        # register self_pid in local_node_agent
        Agent.update(local_node_agent_pid, fn(state) ->
          [{group, self_pid, %{}} | state]
        end)

        # register nodeLevel agent's pid in globalLevel agent
        Agent.update(top_agent_pid, fn({sink, state}) ->
          flag = Enum.any?(state, fn(x) -> x == node_agent_pid end)
            if flag do
              # don't update
              {sink, state}
            else
              if(Enum.member?(group, sink_node_group_name)) do
                {node_agent_pid, [node_agent_pid | state]}
              else
                {sink, [node_agent_pid | state]}
              end
            end
        end)

        # unregister when process is down
        spawn(fn ->
          Process.monitor(self_pid)
          receive do
            msg ->
              Agent.update(node_agent_pid, fn(state) ->
                Enum.filter(state, fn(x) ->
                  {_, pid, _} = x
                  pid != self_pid
                end)
              end)
              Agent.update(local_node_agent_pid, fn(state) ->
                Enum.filter(state, fn(x) ->
                  {_, pid, _} = x
                  pid != self_pid
                end)
              end)
          end
        end)
      end
    end
  end

  def remove_registered_process() do
    top_agent_pid = :global.whereis_name(@top_agent_name)
    {sink, node_agents} = Agent.get(top_agent_pid, &(&1))
    nodes = if sink != nil do
      [sink | node_agents]
    else
      node_agents
    end
    self_pid = self()
    Enum.each(nodes, fn(agent) ->
      spawn(fn ->
        Agent.update(agent, fn(_) -> [] end)
        send self_pid, :ok
      end)
    end)
    Enum.each(nodes, fn(_) ->
      receive do
        :ok -> :ok
      end
    end)
  end

  @doc """
  return nil when pid isn't registered
  """
  defmacro get_activelayers(pid) do
    quote do
      self_pid = unquote(pid)
      node_agent_pid = Process.whereis String.to_atom(unquote(@node_agent_prefix) <> Atom.to_string(node()))
      res1 = Agent.get(node_agent_pid, fn(state) ->
        state |> Enum.find(fn(x) ->
          {_group, p, _layers} = x
          p == self_pid
        end)
      end)
      local_node_agent_pid = Process.whereis String.to_atom(unquote(@local_node_agent_prefix) <> Atom.to_string(node()))
      res2 = Agent.get(local_node_agent_pid, fn(state) ->
        state |> Enum.find(fn(x) ->
          {_group, p, _layers} = x
          p == self_pid
        end)
      end)
      layers1 = case res1 do
          nil -> nil
          {_, _, layers} -> layers
      end
      layers2 = case res2 do
          nil -> nil
          {_, _, layers} -> layers
      end

      if(layers1 != nil && layers2 != nil) do
        Map.merge(layers1,layers2)
      else
        nil
      end

    end
  end

  defmacro get_active_local_layers(pid) do
    quote do
      self_pid = unquote(pid)
      local_node_agent_pid = Process.whereis String.to_atom(unquote(@local_node_agent_prefix) <> Atom.to_string(node()))
      res = Agent.get(local_node_agent_pid, fn(state) ->
        state |> Enum.find(fn(x) ->
          {_group, p, _layers} = x
          p == self_pid
        end)
      end)
      case res do
        nil -> nil
        {_, _, layers} -> layers
      end
    end
  end

  @doc """
  update active layers
  return :ok
  return nil when pid isn't registered
  """
  defmacro cast_activate_layer(pid, map) do
    quote do
      with  self_pid = unquote(pid),
        node_agent_pid = Process.whereis(String.to_atom(unquote(@node_agent_prefix) <> Atom.to_string(node()))),
      do:
        Agent.cast(node_agent_pid, fn(state) ->
          Enum.map(state, fn(x) ->
            case x do
              {group, ^self_pid, layers} ->
                {group, self_pid, Map.merge(layers, unquote(map))}
              x -> x
            end
          end)
        end)
    end
  end

  @doc """
  update active local layers
  return :ok
  return nil when pid isn't registered
  """
  defmacro cast_activate_local_layer(pid, map) do
    quote do
      with  self_pid = unquote(pid),
        local_node_agent_pid = Process.whereis(String.to_atom(unquote(@local_node_agent_prefix) <> Atom.to_string(node()))),
      do:
        Agent.cast(local_node_agent_pid, fn(state) ->
          Enum.map(state, fn(x) ->
            case x do
              {group, ^self_pid, layers} ->
                {group, self_pid, Map.merge(layers, unquote(map))}
              x -> x
            end
          end)
        end)
    end
  end

  @doc """
  update active layers
  return latest active layers
  """
  defmacro call_activate_layer(pid, map) do
    quote bind_quoted: [pid: pid, map: map] do
      cast_activate_layer(pid, map)
      get_activelayers(pid)
    end
  end

  @doc """
  update active local layers
  return latest active local layers
  """
  defmacro call_activate_local_layer(pid, map) do
    quote bind_quoted: [pid: pid, map: map] do
      cast_activate_local_layer(pid, map)
      get_active_local_layers(pid)
    end
  end

  defmacro cast_activate_group(target_group, map) do
    quote bind_quoted: [top_agent_name: @top_agent_name, target_group: target_group, map: map] do
      unless(is_atom(target_group)) do
        raise ArgumentError, message: "target_group must be atom."
      end
      top_agent = :global.whereis_name top_agent_name
      Agent.get(top_agent, fn({sink, state}) ->
        if(target_group == :sink) do
          [sink]
        else
          state
        end
      end) 
      |> Enum.each(fn(pid) ->
        Agent.cast(pid, fn(state) ->
          Enum.map(state, fn({group, pid, layers}) ->
            if(Enum.member?(group, target_group)) do
              {group, pid, Map.merge(layers, map)}
            else
              {group, pid, layers}
            end
          end)
        end)
      end)
    end
  end

  defmacro call_activate_group(target_group, map) do
    quote bind_quoted: [top_agent_name: @top_agent_name, target_group: target_group, map: map] do
      unless(is_atom(target_group)) do
        raise ArgumentError, message: "target_group must be atom."
      end
      top_agent = :global.whereis_name top_agent_name
      self_pid = self()
      node_agents = Agent.get(top_agent, fn({sink, state}) -> if(target_group == :sink) do [sink] else state end end)
      Enum.each(node_agents, fn(pid) ->
        spawn(fn ->
          Agent.update(pid, fn(state) ->
            Enum.map(state, fn({group, pid, layers}) ->
            if(Enum.member?(group, target_group)) do
              {group, pid, Map.merge(layers, map)}
            else
              {group, pid, layers}
            end
            end)
          end)
          send self_pid, :ok
        end)
      end)
      Enum.each(node_agents, fn(_) ->
        receive do
          :ok -> :ok
        end
      end)
    end
  end

  defmacro with_context(map, do: body_exp) do
    quote do
      prev_context = get_active_local_layers()
      cast_activate_local_layer(unquote(map))
      unquote(body_exp)
      cast_activate_local_layer(prev_context)
    end
  end

  defmacro is_active?(pid, layer) do
    quote do
      map = get_activelayers(unquote(pid))
      unquote(layer) in Map.keys(map)
    end
  end

  defmacro deflf({:when, meta, [func, cond_exp]}, do: body_exp) do
    when_clause = {:when, meta, [{:%{}, [], []}, cond_exp]}
    quote do: deflf(unquote(func), unquote(when_clause), do: unquote(body_exp))
  end


  defmacro deflf(func, do: body_exp) do
    quote do: deflf(unquote(func), %{}, do: unquote(body_exp))
  end

  defmacro deflf({name, meta, args_exp}, {:when, meta2, [map_exp, cond_exp]}, do: body_exp) do
    new_definition =
      with  pf_name = partialfunc_name(name),
            new_args = List.insert_at(args_exp, 0, map_exp),
      do: {:when, meta2, [{pf_name, meta, new_args}, cond_exp]}

    quote bind_quoted: [name: name, arity: length(args_exp), body: Macro.escape(body_exp), definition: Macro.escape(new_definition)] do
      # register layered function
      unless @layered_function[name] == arity, do: @layered_function {name, arity}

      # define partialFunc in Caller module
      Kernel.defp(unquote(definition)) do
        unquote(body)
      end
    end
  end

  defmacro deflf({name, meta, args_exp}, map_exp, do: body_exp) do
    new_definition =
      with  pf_name = partialfunc_name(name),
            new_args = List.insert_at(args_exp, 0, map_exp),
      do: {pf_name, meta, new_args}

    quote bind_quoted: [name: name, arity: length(args_exp), body: Macro.escape(body_exp), definition: Macro.escape(new_definition)] do
      # register layered function
      unless @layered_function[name] == arity, do: @layered_function {name, arity}

      # define partialFunc in Caller module
      Kernel.defp(unquote(definition)) do
        unquote(body)
      end
    end
  end

  defmacro deflfp({:when, meta, [func, cond_exp]}, do: body_exp) do
    when_clause = {:when, meta, [{:%{}, [], []}, cond_exp]}
    quote do: deflfp(unquote(func), unquote(when_clause), do: unquote(body_exp))
  end

  defmacro deflfp(func, do: body_exp) do
    quote do: deflfp(unquote(func), %{}, do: unquote(body_exp))
  end

  defmacro deflfp({name, meta, args_exp}, {:when, meta2, [map_exp, cond_exp]}, do: body_exp) do
    new_definition =
      with  pf_name = partialfunc_name(name),
            new_args = List.insert_at(args_exp, 0, map_exp),
      do: {:when, meta2, [{pf_name, meta, new_args}, cond_exp]}

    quote bind_quoted: [name: name, arity: length(args_exp), body: Macro.escape(body_exp), definition: Macro.escape(new_definition)] do
      # register layered function
      unless @layered_private_function[name] == arity, do: @layered_private_function {name, arity}

      # define partialFunc in Caller module
      Kernel.defp(unquote(definition)) do
        unquote(body)
      end
    end
  end

  defmacro deflfp({name, meta, args_exp}, map_exp, do: body_exp) do
    new_definition =
      with pf_name = partialfunc_name(name),
           new_args = List.insert_at(args_exp, 0, map_exp),
        do: {pf_name, meta, new_args}

    quote bind_quoted: [name: name, arity: length(args_exp), body: Macro.escape(body_exp), definition: Macro.escape(new_definition)] do
      unless @layered_private_function[name] == arity, do: @layered_private_function {name, arity}

      Kernel.defp(unquote(definition)) do
        unquote(body)
      end
    end
  end


  defp partialfunc_name(func_name), do: String.to_atom(@partial_prefix <> Atom.to_string(func_name))

  defp gen_genericfunction_ast({func_name, arity}, module) do
    args = gen_dummy_args(arity, module)
    {:def, [context: module, import: Kernel],
      [{func_name, [context: module], args},
       [do:
         {:__block__, [],[
          {:=, [], [{:layer, [], module}, {:get_activelayers, [], []}]},
          {partialfunc_name(func_name), [context: module],
            # pass activated layers for first arg
            List.insert_at(args, 0, {:layer, [], module})}
         ]}]]}
  end

  defp gen_private_genericfunction_ast({func_name, arity}, module) do
    args = gen_dummy_args(arity, module)
    {:defp, [context: module, import: Kernel],
      [{func_name, [context: module], args},
       [do:
         {:__block__, [],[
          {:=, [], [{:layer, [], module}, {:get_activelayers, [], []}]},
          {partialfunc_name(func_name), [context: module],
            # pass activated layers for first arg
            List.insert_at(args, 0, {:layer, [], module})}
         ]}]]}
  end

  defp gen_dummy_args(0, _), do: []
  defp gen_dummy_args(num, module) do
    Enum.map(1.. num, fn(x) ->
      {String.to_atom(@arg_name <> Integer.to_string(x)), [], module}
    end)
  end
end

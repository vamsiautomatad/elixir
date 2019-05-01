defmodule Module.Checker do
  @moduledoc false

  def check(env, set, bag, module_map) do
    make_definition_available(module_map)
    Module.check_behaviours_and_impls(env, set, bag, module_map.definitions)
    check_definitions(module_map, env)
  end

  defp make_definition_available(%{module: module}) do
    case :erlang.get(:elixir_compiler_pid) do
      :undefined -> :ok
      pid -> send(pid, {:available, :definition, module})
    end
  end

  defp check_definitions(%{definitions: definitions, compile_opts: compile_opts}, env) do
    state = %{
      function: nil,
      env: env,
      cached_modules: %{},
      compile_opts: compile_opts
    }

    Enum.reduce(definitions, state, &check_definition/2)
  end

  defp check_definition({def, _kind, _meta, clauses}, state) do
    Enum.reduce(clauses, %{state | function: def}, &check_clause/2)
  end

  defp check_clause({_meta, _args, _guards, body}, state) do
    check_body(body, state)
  end

  defp check_body({:&, _, [{:/, _, [{{:., meta, [mod, fun]}, _, []}, arity]}]}, state)
       when is_atom(mod) and is_atom(fun) do
    fetch_and_check_remote(mod, fun, arity, meta, state)
  end

  defp check_body({{:., meta, [mod, fun]}, _, args}, state)
       when is_atom(mod) and is_atom(fun) do
    fetch_and_check_remote(mod, fun, length(args), meta, state)
  end

  defp check_body({left, _meta, right}, state) when is_list(right) do
    check_body(right, check_body(left, state))
  end

  defp check_body({left, right}, state) do
    check_body(right, check_body(left, state))
  end

  defp check_body([_ | _] = list, state) do
    Enum.reduce(list, state, &check_body/2)
  end

  defp check_body(_other, state) do
    state
  end

  # TODO: Skip the first check only if we are inside a protocol.
  defp fetch_and_check_remote(_mod, :__impl__, 1, _meta, state), do: state
  defp fetch_and_check_remote(:erlang, :orelse, 2, _meta, state), do: state
  defp fetch_and_check_remote(:erlang, :andalso, 2, _meta, state), do: state

  defp fetch_and_check_remote(mod, fun, arity, meta, state) do
    {mod_info, state} = fetch_or_load_module(mod, meta, state)

    cond do
      mod_info == :not_found ->
        if should_warn_undefined?(mod, fun, arity, state) do
          warn(meta, state, __MODULE__, {:undefined_module, mod, fun, arity})
        end

      mod_info == :unknown ->
        :ok

      undefined_remote?(mod_info, fun, arity) ->
        if should_warn_undefined?(mod, fun, arity, state) do
          exports = exports_for(mod_info)
          warn(meta, state, __MODULE__, {:undefined_function, mod, fun, arity, exports})
        end

      deprecated = :elixir_dispatch.check_deprecated(mod, fun, arity, elem(mod_info, 2)) ->
        warn(meta, state, :elixir_dispatch, deprecated)

      true ->
        :ok
    end

    state
  end

  defp undefined_remote?({_, mod, _}, fun, arity) when is_atom(mod),
    do: not :erlang.function_exported(mod, fun, arity)

  defp undefined_remote?({_, exports, _}, fun, arity),
    do: not :lists.member({fun, arity}, exports)

  defp exports_for({_, mod, _}) when is_atom(mod) do
    try do
      mod.__info__(:macros) ++ mod.__info__(:functions)
    rescue
      _ -> mod.module_info(:exports)
    end
  end

  defp exports_for({_, exports, _}), do: exports

  defp should_warn_undefined?(mod, fun, arity, state) do
    triplet = {mod, fun, arity}

    for(
      {:no_warn_undefined, values} <- state.compile_opts,
      value <- List.wrap(values),
      value == mod or value == triplet,
      do: :skip
    ) == []
  end

  # It returns one of:
  #
  #  * :unknown - the module was found but is unknown
  #  * :not_found - the module could not be found
  #  * {module, module, deprecations} - a loaded module
  #  * {module, definitions, deprecations} - self or an external module being compiled
  #
  # Note we optimize :erlang and Kernel as they are common cases.
  defp fetch_or_load_module(Kernel, _meta, state), do: {{Kernel, Kernel, []}, state}
  defp fetch_or_load_module(:erlang, _meta, state), do: {{:erlang, :erlang, []}, state}

  defp fetch_or_load_module(module, meta, %{cached_modules: modules, env: env} = state) do
    case modules do
      %{^module => data} ->
        {data, state}

      %{} ->
        data = load_module(module, meta, env)
        {data, %{state | cached_modules: Map.put(modules, module, data)}}
    end
  end

  defp load_module(module, _meta, %{module: module}) do
    from_ets(module)
  end

  defp load_module(module, meta, _env) do
    # For structs, we look into contextual modules, but here looking at those
    # will always be missing information, so we skip them to avoid false warnings.
    if Keyword.get(meta, :context_module, false) do
      if ensure_loaded(module) == {:module, module}, do: from_info(module), else: :unknown
    else
      case ensure_loaded(module) do
        {:module, _} -> from_info(module)
        {:error, :nofile} -> ensure_compiled(module)
        _ -> :not_found
      end
    end
  end

  # TODO: Do not rely on erlang:module_loaded/1 on Erlang/OTP 21+.
  defp ensure_loaded(module) do
    case :erlang.module_loaded(module) do
      true -> {:module, module}
      false -> :code.ensure_loaded(module)
    end
  end

  defp ensure_compiled(module) do
    if is_pid(:erlang.get(:elixir_compiler_pid)) do
      case Kernel.ErrorHandler.ensure_compiled(module, :definition, :definition) do
        :not_found ->
          :not_found

        :deadlock ->
          :unknown

        :found ->
          try do
            from_ets(module)
          rescue
            ArgumentError -> from_info(module)
          end
      end
    else
      :unknown
    end
  end

  defp from_info(module) do
    {module, module, get_info(module, :deprecated)}
  end

  defp get_info(module, key) do
    if :erlang.function_exported(module, :__info__, 1) do
      try do
        module.__info__(key)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp from_ets(module) do
    {_, bag} = :elixir_module.data_tables(module)
    deprecations = bag_lookup_element(bag, :deprecated, 2)

    # Definitions always need to be looked up last to avoid races.
    defs = [{:__info__, 1} | :ets.lookup_element(bag, :defs, 2)]
    {module, defs, deprecations}
  end

  defp bag_lookup_element(table, key, pos) do
    :ets.lookup_element(table, key, pos)
  rescue
    _ -> []
  end

  ## Errors

  defp warn(meta, %{env: env, function: function}, mod, message) do
    :elixir_errors.form_warn(meta, %{env | function: function}, mod, message)
  end

  def format_error({:undefined_module, mod, fun, arity}) do
    [
      "function ",
      Exception.format_mfa(mod, fun, arity),
      " is undefined (module ",
      inspect(mod),
      " is not available or is yet to be defined)"
    ]
  end

  def format_error({:undefined_function, mod, fun, arity, exports}) do
    [
      "function ",
      Exception.format_mfa(mod, fun, arity),
      " is undefined or private",
      UndefinedFunctionError.hint_for_loaded_module(mod, fun, arity, exports)
    ]
  end
end

# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.Components.Parameters do
  @moduledoc """
  LiveComponent for viewing and editing robot parameters.

  Displays parameters in a tab-based interface with:
  - Local parameter groups as tabs
  - Remote bridge parameters in separate tabs
  - Appropriate input controls based on parameter type
  - Real-time updates via PubSub
  """
  use Phoenix.LiveComponent

  alias BB.Dsl.Info, as: DslInfo
  alias BB.Parameter
  alias BB.Robot.Runtime, as: RobotRuntime

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       tabs: [],
       parameters: %{},
       active_tab: nil,
       error_message: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def update(%{event: {:parameter_changed, path, new_value}}, socket) do
    tab_id = get_tab_id_for_path(path)

    updated_params =
      update_in(socket.assigns.parameters, [tab_id, path], fn param ->
        if param, do: %{param | value: new_value}, else: param
      end)

    {:ok, assign(socket, :parameters, updated_params)}
  end

  def update(%{robot_module: robot_module} = assigns, socket) do
    socket =
      if socket.assigns[:robot_module] != robot_module do
        initialize_for_robot(socket, robot_module)
      else
        socket
      end

    {:ok, assign(socket, assigns)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  defp initialize_for_robot(socket, robot_module) do
    case load_parameters(robot_module) do
      {:ok, tabs, parameters, active_tab} ->
        socket
        |> assign(:robot_module, robot_module)
        |> assign(:tabs, tabs)
        |> assign(:parameters, parameters)
        |> assign(:active_tab, active_tab)

      :error ->
        assign(socket, :robot_module, robot_module)
    end
  end

  defp load_parameters(robot_module) do
    if valid_robot?(robot_module) do
      try do
        {tabs, parameters} = discover_local_parameters(robot_module)
        {bridge_tabs, bridge_params} = discover_bridge_parameters(robot_module)

        all_tabs = tabs ++ bridge_tabs
        all_params = Map.merge(parameters, bridge_params)

        active_tab =
          case all_tabs do
            [first | _] -> first.id
            [] -> nil
          end

        {:ok, all_tabs, all_params, active_tab}
      rescue
        ArgumentError -> :error
      end
    else
      :error
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="bb-parameters">
      <div :if={@error_message} class="bb-error-message" role="alert">
        <span class="bb-error-icon">!</span>
        <span>{@error_message}</span>
      </div>

      <div :if={@tabs == []} class="bb-empty-state">
        <p class="bb-empty-state-message">No parameters defined</p>
      </div>

      <div :if={@tabs != []}>
        <div class="bb-param-tabs">
          <button
            :for={tab <- @tabs}
            type="button"
            class={"bb-param-tab #{if tab.id == @active_tab, do: "active", else: ""} #{tab.type}"}
            phx-click="select_tab"
            phx-target={@myself}
            phx-value-tab={format_tab_id(tab.id)}
          >
            {tab.label}
            <span :if={tab.type == :remote} class="bb-remote-badge">remote</span>
          </button>
        </div>

        <div :if={@active_tab} class="bb-param-content">
          <% tab = Enum.find(@tabs, fn t -> t.id == @active_tab end) %>
          <% tab_params = Map.get(@parameters, @active_tab, %{}) %>

          <div :if={is_map(tab_params) and Map.has_key?(tab_params, :__error__)} class="bb-param-error">
            <p class="bb-error-text">{tab_params.__error__}</p>
            <button
              :if={tab.type == :remote}
              type="button"
              class="bb-button bb-button-outline"
              phx-click="refresh_remote"
              phx-target={@myself}
              phx-value-bridge={tab.bridge_name}
            >
              Refresh
            </button>
          </div>

          <div
            :if={is_map(tab_params) and not Map.has_key?(tab_params, :__error__)}
            class="bb-param-list"
          >
            <div :if={tab_params == %{}} class="bb-empty-state">
              <p class="bb-empty-state-message">No parameters in this group</p>
            </div>

            <div :for={{_key, param} <- Enum.sort_by(tab_params, fn {_k, p} -> p.display_name end)} class="bb-param-row">
              <div class="bb-param-info">
                <span class="bb-param-name">{param.display_name}</span>
                <span :if={param.doc} class="bb-param-doc">{param.doc}</span>
              </div>
              <div class="bb-param-input">
                {render_param_input(assigns, param, tab)}
              </div>
            </div>

            <button
              :if={tab.type == :remote}
              type="button"
              class="bb-button bb-button-outline bb-refresh-btn"
              phx-click="refresh_remote"
              phx-target={@myself}
              phx-value-bridge={tab.bridge_name}
            >
              Refresh
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_param_input(assigns, param, tab) do
    has_limits = param.min != nil and param.max != nil
    is_remote = tab.type == :remote
    path_str = format_path_string(param[:path] || param[:id])

    # These templates are rendered with the component's assigns, whose
    # `__changed__` only ever names the component's own assigns. A key added
    # with `Map.put` is missing from it, so LiveView treats `@value` and the
    # rest as unchanged and leaves them out of the diff: the inputs would keep
    # the value they were first rendered with. `assign/3` marks them changed.
    assigns =
      assigns
      |> assign(:param, param)
      |> assign(:is_remote, is_remote)
      |> assign(:bridge_name, if(is_remote, do: tab.bridge_name, else: ""))
      |> assign(:path_str, path_str)

    input_type = determine_input_type(param.type, has_limits)
    render_input_by_type(input_type, assigns)
  end

  defp determine_input_type("boolean", _has_limits), do: :boolean
  defp determine_input_type("atom", _has_limits), do: :atom
  defp determine_input_type("float", true), do: :slider
  defp determine_input_type("float", false), do: :number
  defp determine_input_type("integer", true), do: :slider
  defp determine_input_type("integer", false), do: :number
  defp determine_input_type("unit:" <> _, true), do: :slider
  defp determine_input_type("unit:" <> _, false), do: :number
  defp determine_input_type(_, _has_limits), do: :text

  defp render_input_by_type(:boolean, assigns), do: render_boolean_input(assigns)
  defp render_input_by_type(:slider, assigns), do: render_slider_input(assigns)
  defp render_input_by_type(:number, assigns), do: render_number_input(assigns)
  defp render_input_by_type(:atom, assigns), do: render_atom_input(assigns)
  defp render_input_by_type(:text, assigns), do: render_text_input(assigns)

  defp render_boolean_input(assigns) do
    ~H"""
    <label class="bb-toggle">
      <input
        type="checkbox"
        checked={@param.value == true}
        phx-click="toggle_boolean"
        phx-target={@myself}
        phx-value-path={@path_str}
        phx-value-remote={to_string(@is_remote)}
        phx-value-bridge={@bridge_name}
      />
      <span class="bb-toggle-slider"></span>
    </label>
    """
  end

  defp render_slider_input(assigns) do
    {value, unit} = magnitude_and_unit(assigns.param.value, assigns.param.type)
    {min, _unit} = magnitude_and_unit(assigns.param.min, assigns.param.type)
    {max, _unit} = magnitude_and_unit(assigns.param.max, assigns.param.type)

    step = if assigns.param.type == "integer", do: "1", else: to_string((max - min) / 100)

    assigns =
      assigns
      |> assign(:step, step)
      |> assign(:unit, unit)
      |> assign(:min, min)
      |> assign(:max, max)
      |> assign(:value, value || 0)

    ~H"""
    <div class="bb-slider-input" id={"slider-#{@path_str}"}>
      <form id={"param-range-#{@path_str}"} phx-change="set_parameter" phx-target={@myself}>
        <.param_identity path={@path_str} remote={@is_remote} bridge={@bridge_name} />
        <input
          type="range"
          name="value"
          min={@min}
          max={@max}
          step={@step}
          value={@value}
          phx-debounce="100"
        />
      </form>
      <form
        id={"param-number-#{@path_str}"}
        phx-change="set_parameter"
        phx-submit="set_parameter"
        phx-target={@myself}
      >
        <.param_identity path={@path_str} remote={@is_remote} bridge={@bridge_name} />
        <input
          type="number"
          name="value"
          min={@min}
          max={@max}
          step={@step}
          value={@value}
          phx-debounce="blur"
          class="bb-input"
        />
        <span :if={@unit} class="bb-unit-label">{@unit}</span>
      </form>
    </div>
    """
  end

  defp render_number_input(assigns) do
    {value, unit} = magnitude_and_unit(assigns.param.value, assigns.param.type)
    step = if assigns.param.type == "integer", do: "1", else: "0.01"

    assigns =
      assigns
      |> assign(:step, step)
      |> assign(:unit, unit)
      |> assign(:value, value || 0)

    ~H"""
    <div class="bb-number-input">
      <form
        id={"param-number-#{@path_str}"}
        phx-change="set_parameter"
        phx-submit="set_parameter"
        phx-target={@myself}
      >
        <.param_identity path={@path_str} remote={@is_remote} bridge={@bridge_name} />
        <input
          type="number"
          name="value"
          step={@step}
          value={@value}
          phx-debounce="blur"
          class="bb-input"
        />
        <span :if={@unit} class="bb-unit-label">{@unit}</span>
      </form>
    </div>
    """
  end

  defp render_atom_input(assigns) do
    display_value = if assigns.param.value, do: ":#{assigns.param.value}", else: ""
    assigns = assign(assigns, :display_value, display_value)

    ~H"""
    <form
      id={"param-atom-#{@path_str}"}
      phx-change="set_parameter"
      phx-submit="set_parameter"
      phx-target={@myself}
    >
      <.param_identity path={@path_str} remote={@is_remote} bridge={@bridge_name} />
      <input
        type="text"
        name="value"
        value={@display_value}
        phx-debounce="blur"
        class="bb-input bb-atom-input"
      />
    </form>
    """
  end

  defp render_text_input(assigns) do
    ~H"""
    <form
      id={"param-text-#{@path_str}"}
      phx-change="set_parameter"
      phx-submit="set_parameter"
      phx-target={@myself}
    >
      <.param_identity path={@path_str} remote={@is_remote} bridge={@bridge_name} />
      <input
        type="text"
        name="value"
        value={@param.value || ""}
        phx-debounce="blur"
        class="bb-input"
      />
    </form>
    """
  end

  # LiveView reads `phx-value-*` from the form for change and submit events, not
  # from the input that changed, so which parameter a form writes to has to
  # travel as form data.
  attr(:path, :string, required: true)
  attr(:remote, :boolean, required: true)
  attr(:bridge, :string, required: true)

  defp param_identity(assigns) do
    ~H"""
    <input type="hidden" name="path" value={@path} />
    <input type="hidden" name="remote" value={to_string(@remote)} />
    <input type="hidden" name="bridge" value={@bridge} />
    """
  end

  # A unit-typed parameter can hold any value compatible with its declared unit
  # — `BB.Parameter` stores whatever was written rather than converting — so the
  # magnitude is only comparable with the declared bounds once it has been
  # converted into the declared unit.
  defp magnitude_and_unit(nil, _type), do: {nil, nil}

  defp magnitude_and_unit(%Localize.Unit{} = value, "unit:" <> declared) do
    converted = in_unit(value, BB.Unit.unit_name(declared))
    {converted.value, converted.name}
  end

  defp magnitude_and_unit(%Localize.Unit{} = value, _type), do: {value.value, value.name}
  defp magnitude_and_unit(value, _type), do: {value, nil}

  defp in_unit(%Localize.Unit{name: name} = value, name), do: value

  defp in_unit(value, name) do
    case Localize.Unit.convert(value, name) do
      {:ok, converted} -> converted
      {:error, _reason} -> value
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_tab", %{"tab" => tab_str}, socket) do
    tab_id = parse_tab_id(tab_str)
    {:noreply, assign(socket, :active_tab, tab_id)}
  end

  def handle_event("toggle_boolean", params, socket) do
    path_str = params["path"]
    is_remote = params["remote"] == "true"
    bridge = params["bridge"]
    current_value = Map.get(find_param(socket, path_str, is_remote, bridge), :value)

    apply_parameter_change(socket, path_str, not (current_value == true), is_remote, bridge)
  end

  def handle_event("set_parameter", params, socket) do
    path_str = params["path"]
    value = params["value"]
    is_remote = params["remote"] == "true"
    bridge = params["bridge"]
    param_type = Map.get(find_param(socket, path_str, is_remote, bridge), :type, "string")

    parsed_value = parse_value(value, param_type)
    apply_parameter_change(socket, path_str, parsed_value, is_remote, bridge)
  end

  def handle_event("refresh_remote", %{"bridge" => bridge_str}, socket) do
    bridge_atom = String.to_existing_atom(bridge_str)
    params = fetch_remote_params(socket.assigns.robot_module, bridge_atom)
    tab_id = {:bridge, bridge_atom}

    updated_params = Map.put(socket.assigns.parameters, tab_id, params)
    {:noreply, assign(socket, :parameters, updated_params)}
  end

  defp apply_parameter_change(socket, path_str, value, is_remote, bridge) do
    result =
      if is_remote do
        bridge_atom = String.to_existing_atom(bridge)
        Parameter.set_remote(socket.assigns.robot_module, bridge_atom, path_str, value)
      else
        Parameter.set(socket.assigns.robot_module, parse_path(path_str), value)
      end

    {:noreply, assign(socket, :error_message, refusal(result))}
  end

  defp refusal(:ok), do: nil
  defp refusal({:error, reason}) when is_exception(reason), do: Exception.message(reason)
  defp refusal({:error, reason}), do: inspect(reason)

  # Remote parameters are keyed in their bridge's tab by the id the bridge gave
  # them, which is a string of the remote system's choosing rather than a path.
  defp find_param(socket, param_id, true = _is_remote, bridge) do
    bridge_atom = String.to_existing_atom(bridge)

    socket.assigns.parameters
    |> Map.get({:bridge, bridge_atom}, %{})
    |> Map.get(param_id, %{})
  end

  defp find_param(socket, path_str, false = _is_remote, _bridge) do
    path = parse_path(path_str)

    socket.assigns.parameters
    |> Map.get(get_tab_id_for_path(path), %{})
    |> Map.get(path, %{})
  end

  defp get_tab_id_for_path(path) do
    case path do
      [single] when is_atom(single) -> :general
      [group | _] -> group
    end
  end

  # Parameter discovery

  defp discover_local_parameters(robot_module) do
    params = Parameter.list(robot_module)
    organise_into_tabs(params)
  end

  defp organise_into_tabs(params) do
    grouped =
      params
      |> Enum.group_by(fn {path, _meta} ->
        case path do
          [single] when is_atom(single) -> :general
          [group | _rest] -> group
        end
      end)

    tabs =
      grouped
      |> Map.keys()
      |> Enum.sort_by(fn
        :general -> {0, ""}
        name -> {1, Atom.to_string(name)}
      end)
      |> Enum.map(fn group ->
        %{
          id: group,
          label: format_tab_label(group),
          type: :local
        }
      end)

    parameters =
      grouped
      |> Enum.map(fn {group, params_list} ->
        formatted =
          params_list
          |> Enum.map(&format_local_param/1)
          |> Enum.sort_by(& &1.display_name)
          |> Map.new(fn p -> {p.path, p} end)

        {group, formatted}
      end)
      |> Map.new()

    {tabs, parameters}
  end

  defp format_tab_label(:general), do: "General"
  defp format_tab_label(name), do: name |> Atom.to_string() |> String.capitalize()

  defp format_local_param({path, meta}) do
    display_name =
      case path do
        [_single] -> Atom.to_string(hd(path))
        [_group | rest] -> Enum.map_join(rest, ".", &Atom.to_string/1)
      end

    %{
      path: path,
      display_name: display_name,
      value: meta[:value],
      type: format_type(meta[:type]),
      min: meta[:min],
      max: meta[:max],
      doc: meta[:doc]
    }
  end

  defp format_type(nil), do: "string"
  defp format_type(type) when is_atom(type), do: Atom.to_string(type)
  defp format_type({:unit, unit}), do: "unit:#{unit}"
  defp format_type(other), do: inspect(other)

  defp discover_bridge_parameters(robot_module) do
    simulation_mode = RobotRuntime.simulation_mode(robot_module)

    bridges =
      robot_module
      |> DslInfo.parameters()
      |> Enum.filter(&is_struct(&1, BB.Dsl.Bridge))
      |> Enum.reject(fn bridge ->
        simulation_mode != nil and bridge.simulation == :omit
      end)

    tabs =
      Enum.map(bridges, fn bridge ->
        %{
          id: {:bridge, bridge.name},
          label: bridge.name |> Atom.to_string() |> String.capitalize(),
          type: :remote,
          bridge_name: bridge.name
        }
      end)

    parameters =
      bridges
      |> Enum.map(fn bridge ->
        params = fetch_remote_params(robot_module, bridge.name)
        {{:bridge, bridge.name}, params}
      end)
      |> Map.new()

    {tabs, parameters}
  end

  defp fetch_remote_params(robot_module, bridge_name) do
    case Parameter.list_remote(robot_module, bridge_name) do
      {:ok, params} ->
        params
        |> Enum.map(fn p ->
          id = p[:id] || p["id"]

          %{
            id: id,
            display_name: id,
            value: p[:value] || p["value"],
            type: format_type(p[:type] || p["type"]),
            min: p[:min] || p["min"],
            max: p[:max] || p["max"],
            doc: p[:doc] || p["doc"]
          }
        end)
        |> Map.new(fn p -> {p.id, p} end)

      {:error, _reason} ->
        %{__error__: "Failed to load remote parameters"}
    end
  end

  # Tab ID formatting

  defp format_tab_id(:general), do: "general"
  defp format_tab_id({:bridge, name}), do: "bridge:#{name}"
  defp format_tab_id(name) when is_atom(name), do: Atom.to_string(name)

  defp parse_tab_id("general"), do: :general
  defp parse_tab_id("bridge:" <> name), do: {:bridge, String.to_existing_atom(name)}
  defp parse_tab_id(name), do: String.to_existing_atom(name)

  defp format_path_string(path) when is_list(path),
    do: Enum.map_join(path, ".", &Atom.to_string/1)

  defp format_path_string(id), do: to_string(id)

  defp parse_path(path_str) do
    path_str
    |> String.split(".")
    |> Enum.map(&String.to_existing_atom/1)
  end

  # Value parsing

  defp parse_value(value, "boolean"), do: value == true or value == "true"

  defp parse_value(value, "integer") do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> value
    end
  end

  defp parse_value(value, "float"), do: parse_float_value(value)

  defp parse_value(value, "unit:" <> declared) do
    with magnitude when is_number(magnitude) <- parse_float_value(value),
         {:ok, parsed} <- Localize.Unit.new(magnitude, BB.Unit.unit_name(declared)) do
      parsed
    else
      _ -> value
    end
  end

  defp parse_value(value, "atom") do
    name = value |> to_string() |> String.trim_leading(":")

    try do
      String.to_existing_atom(name)
    rescue
      # An atom the runtime has never heard of can't be a legal value for the
      # parameter either, so hand the text on and let the store refuse it.
      ArgumentError -> name
    end
  end

  defp parse_value(value, _type), do: value

  defp parse_float_value(value) do
    case Float.parse(to_string(value)) do
      {float, _} -> float
      :error -> value
    end
  end

  defp valid_robot?(robot_module) when is_atom(robot_module) do
    function_exported?(robot_module, :robot, 0) and
      function_exported?(robot_module, :spark_dsl_config, 0)
  end

  defp valid_robot?(_), do: false
end

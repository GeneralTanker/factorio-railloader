local bulk = require "bulk"

local util = {}

-- Position adjustments

function util.moveposition(position, offset)
	return {x=position.x + offset.x, y=position.y + offset.y}
end

function util.offset(direction, longitudinal, orthogonal)
	if direction == defines.direction.north then
		return {x=orthogonal, y=-longitudinal}
	end

	if direction == defines.direction.south then
		return {x=-orthogonal, y=longitudinal}
	end

	if direction == defines.direction.east then
		return {x=longitudinal, y=orthogonal}
	end

	if direction == defines.direction.west then
		return {x=-longitudinal, y=-orthogonal}
	end
end

function util.box_centered_at(position, radius)
  return {
    left_top = util.moveposition(position, util.offset(defines.direction.north, radius, -radius)),
    right_bottom = util.moveposition(position, util.offset(defines.direction.south, radius, -radius)),
  }
end

function util.orthogonal_direction(direction)
  if direction < 6 then
    return direction + 2
  end
  return 0
end

-- constants

local train_types = {
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
  ["fluid-wagon"] = true,
}

local function abort_build(event)
  local entity = event.created_entity
  local item_name = next(entity.prototype.items_to_place_this)
  if event.player_index then
    local player = game.players[event.player_index]
    local cursor = player.cursor_stack
    if event.revived or cursor.valid_for_read and cursor.name == item_name then
      -- nanobot build or cursor build
      player.insert{name = item_name, count = 1}
    else
      -- last item in cursor, replace it
      player.cursor_stack.set_stack{name = item_name, count = 1}
    end
    entity.destroy()
  else
    -- robot build
    entity.order_deconstruction(entity.force)
  end
end

local function on_rail_ghost_built(event)
  local entity = event.created_entity
  local colliding = entity.surface.find_entities_filtered{
    area = entity.bounding_box,
  }

  for _, other in ipairs(colliding) do
    log("colliding entity: "..other.name)
    if string.find(entity.ghost_name, "^rail(.*)%-placement%-proxy") and
        other.unit_number ~= entity.unit_number then
      -- placing other rails over railloader
      log("found railloader")
      entity.destroy()
      return
    end
    if other.name == "railloader-rail" or
        other.name == "entity-ghost" and
        string.find(other.ghost_name, "^rail(.*)%-placement%-proxy$") and
        other.unit_number ~= entity.unit_number then
      -- placing railloader over other rails
      log("found railloader")
      entity.destroy()
      return
    end
  end
end

local function on_built(event)
  local entity = event.created_entity
  if entity.name == "entity-ghost" and string.find(entity.ghost_type, "rail") then
    return on_rail_ghost_built(event)
  end
  local type = string.match(entity.name, "^rail(.*)%-placement%-proxy$")
  if not type then
    return
  end

  local surface = entity.surface
  local direction = entity.direction
  local position = util.moveposition(entity.position, util.offset(direction, 1.5, 0))
  local force = entity.force

  local rail = surface.find_entities_filtered{
    area = util.box_centered_at(position, 0.5),
    type = "straight-rail",
  }[1]
  if not rail then
    abort_build(event)
    return
  end

  -- center over the rail
  if rail.direction == defines.direction.north then
    position.x = rail.position.x
  else
    position.y = rail.position.y
  end

  entity.destroy()

  -- place chest
  surface.create_entity{
    name = "rail" .. type .. "-chest",
    position = position,
    force = force,
  }

  -- place inserter
  local inserter = surface.create_entity{
    name = "rail" .. type .. "-inserter",
    position = position,
    direction = direction,
    force = force,
  }
  inserter.destructible = false

  -- place structure
  if type == "loader" then
    local placed = surface.create_entity{
      name = "railloader-structure",
      position = position,
      force = force,
    }
    placed.destructible = false
  end
end

local function on_mined(event)
  local entity = event.entity
  local type = string.match(entity.name, "^rail(.*)%-chest$")
  if not type then
    return
  end

  local entities = entity.surface.find_entities_filtered{
    area = entity.bounding_box,
  }
  for _, ent in ipairs(entities) do
    if ent.name == "rail" .. type .. "-inserter" then
      if event.buffer then
        event.buffer.insert(ent.held_stack)
      end
      ent.destroy()
    elseif ent.name == "railloader-structure" then
      ent.destroy()
    end
  end
end

local function on_blueprint(event)
  local player = game.players[event.player_index]
  local bp = player.blueprint_to_setup
  if event.alt then
    bp = player.cursor_stack
  end

  -- find bp center coordinate

  -- find (un)loaders and their directions
  local containers = player.surface.find_entities_filtered{
    area = event.area,
    type = "container",
  }
  local directions = {}
  for _, container in ipairs(containers) do
    if container.name == "railloader-chest" or container.name == "railunloader-chest" then
      local rail = player.surface.find_entities_filtered{
        name = "straight-rail",
        area = util.box_centered_at(container.position, 0.5),
      }[1]
      if rail then
        directions[#directions+1] = rail.direction
      end
    end
  end

  local entities = bp.get_blueprint_entities()
  local loader_index = 1
  for _, e in ipairs(entities) do
    if e.name == "railloader-chest" then
      e.name = "railloader-placement-proxy"
      e.position = util.moveposition(e.position, util.offset(directions[loader_index], 0, -1.5))
      e.direction = util.orthogonal_direction(directions[loader_index])
      loader_index = loader_index + 1
    elseif e.name == "railunloader-chest" then
      e.name = "railunloader-placement-proxy"
      e.position = util.moveposition(e.position, util.offset(directions[loader_index], 0, -1.5))
      e.direction = util.orthogonal_direction(directions[loader_index])
      loader_index = loader_index + 1
    end
  end

  bp.set_blueprint_entities(entities)
end

local function on_selection_changed(event)
  local entity = game.players[event.player_index].selected
  if not entity or (entity.name ~= "railloader-chest" and entity.name ~= "railunloader-chest") then
    return
  end

  -- look for train in the way
  local entities = entity.surface.find_entities_filtered{
    area = entity.bounding_box,
  }
  for _, ent in ipairs(entities) do
    if train_types[ent.type] then
      entity.minable = false
      return
    end
  end
  entity.minable = true
end

local function enable_inserter(inserter, wagon)
  local inventory = wagon.get_inventory(defines.inventory.cargo_wagon)
  if inserter.name == "railloader-inserter" then
    local chest = inserter.surface.find_entity("railloader-chest", inserter.position)
    inventory = chest.get_inventory(defines.inventory.chest)
  end
  local item = bulk.first_acceptable_item(inventory)
  inserter.set_filter(1, item)
end

local function disable_inserter(inserter)
  inserter.set_filter(1, nil)
end

local function on_train_changed_state(event)
  local train = event.train
  for _, wagon in ipairs(train.cargo_wagons) do
    local inserter = wagon.surface.find_entities_filtered{
      type = "inserter",
      position = wagon.position,
    }[1]
    if inserter then
      if train.state == defines.train_state.wait_station then
        enable_inserter(inserter, wagon)
      else
        disable_inserter(inserter)
      end
    end
  end
end

script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, on_built)
script.on_event({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity}, on_mined)
script.on_event(defines.events.on_entity_died, on_mined)
script.on_event(defines.events.on_player_setup_blueprint, on_blueprint)
script.on_event(defines.events.on_selected_entity_changed, on_selection_changed)
script.on_event(defines.events.on_train_changed_state, on_train_changed_state)
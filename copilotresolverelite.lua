-- copilotresolver.lua
-- Copilot Resolver (state-aware, learning, anti-bruteforce) for GameSense
-- Vector/animlayer-inspired logic, no adaptive weapons, no direct viewangle writes.

-- ─────────────────────────────── FFI: entity/layers ───────────────────────────────
local ffi = require("ffi")
local vtptr_t   = ffi.typeof("void***")
local getent_t  = ffi.typeof("void*(__thiscall*)(void*, int)")
ffi.cdef[[
    struct copilot_animation_layer_t {
        char  pad_0000[20];
        uint32_t m_nOrder;
        uint32_t m_nSequence;
        float m_flPrevCycle;
        float m_flWeight;
        float m_flWeightDeltaRate;
        float m_flPlaybackRate;
        float m_flCycle;
        void *m_pOwner;
        char  pad_0038[4];
    };
]]
local entlist = client.create_interface("client_panorama.dll", "VClientEntityList003") or error("VClientEntityList003 not found")
local entlist_vt    = ffi.cast(vtptr_t, entlist)
local get_client_entity = ffi.cast(getent_t, entlist_vt[0][3])

local function get_entity_ptr(entindex)
    if entindex == nil then return nil end
    return get_client_entity(entlist, entindex)
end

-- Note: layer offset heuristic; safe-fallback returns nil if layout mismatches.
local function get_animation_layer(thisptr, i)
    if not thisptr then return nil end
    local base = ffi.cast("char*", thisptr)
    -- conservative layer table guess near 0x2980 + 0x5978 from common builds (Angel-inspired)
    local layers_ptr = ffi.cast("struct copilot_animation_layer_t**", base + 0x2990 + 0x5950)
    if layers_ptr == nil or layers_ptr[0] == nil then return nil end
    return layers_ptr[0][i]
end

-- ─────────────────────────────── Math helpers ───────────────────────────────
local function normalize_angle(a) return (a + 180) % 360 - 180 end
local function angle_diff(a, b) return normalize_angle(a - b) end
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi else return x end end

-- ─────────────────────────────── State tracking ───────────────────────────────
local STATE = { INVALID=0, STANDING=1, MOVING=2, AIR=3, CROUCHING=4, CROUCH_MOVING=5, AIR_CROUCH=6, RUSHING=7 }
local STATE_NAME = {
    [0]="INVALID",[1]="STANDING",[2]="MOVING",[3]="AIR",
    [4]="CROUCH",[5]="CROUCH MOV",[6]="AIR CROUCH",[7]="RUSH"
}
local FL_ONGROUND = bit.lshift(1, 0)
local FL_DUCKING  = bit.lshift(1, 1)
local SPEED_RUSH = 100
local RUSH_DIST  = 600

local player_data   = {}   -- per-entity live state
local resolve_hist  = {}   -- learning history
local resolve_prog  = {}   -- progression/stage
local resolve_view  = {}   -- for visuals
local brute_state   = {}   -- anti-bruteforce per-entity

local function init_player(ent)
    if not player_data[ent] then
        player_data[ent] = {
            entity_ptr=nil,
            state=STATE.INVALID, previous_state=STATE.INVALID,
            position={x=0,y=0,z=0}, velocity={x=0,y=0,z=0},
            aim={pitch=0,yaw=0}, lby_yaw=0, desync=0, desync_side=0,
            last_update_time=0, animation_layers={},
            optimal_offsets={
                [STATE.STANDING]=30,[STATE.MOVING]=20,[STATE.AIR]=0,
                [STATE.CROUCHING]=-10,[STATE.CROUCH_MOVING]=15,[STATE.AIR_CROUCH]=0,[STATE.RUSHING]=25
            },
            weights={
                [STATE.STANDING]=1,[STATE.MOVING]=1,[STATE.AIR]=1,[STATE.CROUCHING]=1,
                [STATE.CROUCH_MOVING]=1,[STATE.AIR_CROUCH]=1,[STATE.RUSHING]=1
            }
        }
    end
    return player_data[ent]
end

local function init_hist(ent)
    if not resolve_hist[ent] then
        local h = {
            hits=0, misses=0, total_shots=0, resolve_confidence=0,
            hits_by_state={}, misses_by_state={}, successful_yaws={}, failed_yaws={}
        }
        for _, st in pairs(STATE) do if type(st)=="number" then h.hits_by_state[st]=0; h.misses_by_state[st]=0 end end
        resolve_hist[ent] = h
    end
    return resolve_hist[ent]
end

local function init_prog(ent)
    if not resolve_prog[ent] then
        resolve_prog[ent] = { stage=1, progress=0, start_time=globals.realtime(), last_update=globals.realtime(), is_resolved=false }
    end
    return resolve_prog[ent]
end

local function init_brute(ent)
    if not brute_state[ent] then
        brute_state[ent] = { idx=1, consecutive_misses=0, seq={1,2,3} } -- 1:+base, 2:-base, 3:extended
    end
    return brute_state[ent]
end

-- ─────────────────────────────── UI ───────────────────────────────
local col_default = { 180, 90, 255 }
local cp_color = ui.new_color_picker("Rage", "Other", "Copilot Resolver color", col_default[1], col_default[2], col_default[3], 255)

local ui_root = {
    header      = ui.new_label("Rage", "Other", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"),
    title       = ui.new_label("Rage", "Other", "Copilot Resolver"),
    enable      = ui.new_checkbox("Rage", "Other", "Enable resolver"),
    debug_logs  = ui.new_checkbox("Rage", "Other", "Debug logs"),
    visualize   = ui.new_checkbox("Rage", "Other", "Visualize resolver"),
    esp_flags   = ui.new_checkbox("Rage", "Other", "ESP flags"),

    state_hdr   = ui.new_label("Rage", "Other", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"),
    state_title = ui.new_label("Rage", "Other", "-=- State analysis -=-"),

    auto_learn  = ui.new_checkbox("Rage", "Other", "Auto-learning"),
    learn_spd   = ui.new_slider("Rage", "Other", "Learning speed", 0, 100, 40, true, "%"),

    air_state   = ui.new_checkbox("Rage", "Other", "Override AIR"),
    air_offs    = ui.new_slider("Rage", "Other", "AIR offset", -60, 60, 0, true, "°"),
    crouch_state= ui.new_checkbox("Rage", "Other", "Override CROUCH"),
    crouch_offs = ui.new_slider("Rage", "Other", "CROUCH offset", -60, 60, -10, true, "°"),
    rush_state  = ui.new_checkbox("Rage", "Other", "Override RUSH"),
    rush_offs   = ui.new_slider("Rage", "Other", "RUSH offset", -60, 60, 25, true, "°"),

    anti_brute  = ui.new_checkbox("Rage", "Other", "Anti-bruteforce cycle"),
    brute_boost = ui.new_slider("Rage", "Other", "Brute extend (deg)", 0, 40, 20, true, "°"),

    perf_hdr    = ui.new_label("Rage", "Other", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"),
    perf_title  = ui.new_label("Rage", "Other", "Performance"),
    fast_upd    = ui.new_checkbox("Rage", "Other", "Optimized tick updates"),
    upd_rate    = ui.new_slider("Rage", "Other", "Update rate", 1, 32, 8, true, "tick"),

    pred        = ui.new_checkbox("Rage", "Other", "Prediction overlay"),
    pred_str    = ui.new_slider("Rage", "Other", "Prediction strength", 0, 100, 40, true, "%"),

    footer      = ui.new_label("Rage", "Other", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"),
    credits     = ui.new_label("Rage", "Other", "Copilot Resolver | Vector/Animlayer-inspired")
}
local plist_refs = {
    AAcorr    = ui.reference("Rage", "Other", "Anti-Aim Correction"),
    ResetAll  = ui.reference("Players", "Players", "Reset All"),
    ForceBody = ui.reference("Players", "Adjustments", "Force Body Yaw"),
    CorrActive= ui.reference("Players", "Adjustments", "Correction Active")
}

local function update_ui_vis()
    local en = ui.get(ui_root.enable)
    ui.set_visible(ui_root.debug_logs, en)
    ui.set_visible(ui_root.visualize, en)
    ui.set_visible(ui_root.esp_flags, en)

    ui.set_visible(ui_root.state_hdr, en)
    ui.set_visible(ui_root.state_title, en)

    ui.set_visible(ui_root.auto_learn, en)
    local al = en and ui.get(ui_root.auto_learn)
    ui.set_visible(ui_root.learn_spd, en and al)

    ui.set_visible(ui_root.air_state, en)
    ui.set_visible(ui_root.air_offs, en and ui.get(ui_root.air_state) and not al)
    ui.set_visible(ui_root.crouch_state, en)
    ui.set_visible(ui_root.crouch_offs, en and ui.get(ui_root.crouch_state) and not al)
    ui.set_visible(ui_root.rush_state, en)
    ui.set_visible(ui_root.rush_offs, en and ui.get(ui_root.rush_state) and not al)

    ui.set_visible(ui_root.anti_brute, en)
    ui.set_visible(ui_root.brute_boost, en and ui.get(ui_root.anti_brute))

    ui.set_visible(ui_root.perf_hdr, en)
    ui.set_visible(ui_root.perf_title, en)
    ui.set_visible(ui_root.fast_upd, en)
    ui.set_visible(ui_root.upd_rate, en and ui.get(ui_root.fast_upd))

    ui.set_visible(ui_root.pred, en)
    ui.set_visible(ui_root.pred_str, en and ui.get(ui_root.pred))

    -- prevent player-list toggles fighting resolver
    ui.set_visible(plist_refs.ForceBody, not en)
    ui.set_visible(plist_refs.CorrActive, not en)
    if not en then ui.set(plist_refs.ResetAll, true) end
end
ui.set_callback(ui_root.enable,       update_ui_vis)
ui.set_callback(ui_root.auto_learn,   update_ui_vis)
ui.set_callback(ui_root.air_state,    update_ui_vis)
ui.set_callback(ui_root.crouch_state, update_ui_vis)
ui.set_callback(ui_root.rush_state,   update_ui_vis)
ui.set_callback(ui_root.fast_upd,     update_ui_vis)
ui.set_callback(ui_root.pred,         update_ui_vis)
ui.set_callback(ui_root.anti_brute,   update_ui_vis)
update_ui_vis()

-- ─────────────────────────────── Acquire state ───────────────────────────────
local function get_state(ent)
    local pd = init_player(ent)
    local now = globals.curtime()
    if now - pd.last_update_time < 0.01 then return pd end

    local ep = get_entity_ptr(ent)
    if not ep then return pd end
    pd.entity_ptr = ep

    local ox, oy, oz = entity.get_origin(ent)
    pd.position.x, pd.position.y, pd.position.z = ox or 0, oy or 0, oz or 0

    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    pd.velocity.x, pd.velocity.y, pd.velocity.z = vx, vy, vz

    local epitch, eyaw = entity.get_prop(ent, "m_angEyeAngles")
    pd.aim.pitch = epitch or 0
    pd.aim.yaw   = eyaw or 0
    pd.lby_yaw   = entity.get_prop(ent, "m_flLowerBodyYawTarget") or 0
    pd.desync    = angle_diff(pd.aim.yaw, pd.lby_yaw)
    pd.desync_side = (pd.desync > 0) and 1 or -1

    -- layers snapshot
    pd.animation_layers = {}
    for i=0,12 do
        local layer = get_animation_layer(ep, i)
        if layer ~= nil then
            pd.animation_layers[i] = {
                sequence = layer.m_nSequence,
                prev_cycle = layer.m_flPrevCycle,
                weight = layer.m_flWeight,
                playback_rate = layer.m_flPlaybackRate,
                cycle = layer.m_flCycle
            }
        end
    end

    -- state classify
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local on_ground = bit.band(flags, FL_ONGROUND) ~= 0
    local ducking   = bit.band(flags, FL_DUCKING) ~= 0
    local speed2d = math.sqrt(vx*vx + vy*vy)
    local moving = speed2d > 5

    pd.previous_state = pd.state
    if not on_ground then
        pd.state = ducking and STATE.AIR_CROUCH or STATE.AIR
    elseif ducking then
        pd.state = moving and STATE.CROUCH_MOVING or STATE.CROUCHING
    elseif moving then
        pd.state = STATE.MOVING
    else
        pd.state = STATE.STANDING
    end

    -- rushing detection
    local me = entity.get_local_player()
    if me and speed2d > SPEED_RUSH then
        local mx,my,mz = entity.get_origin(me)
        if mx then
            local dx,dy,dz = (mx-ox),(my-oy),(mz-oz)
            local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist < RUSH_DIST then
                local inv = 1/(math.sqrt(vx*vx+vy*vy+vz*vz) + 1e-6)
                local vnx, vny, vnz = vx*inv, vy*inv, vz*inv
                local invd = 1/(math.sqrt(dx*dx+dy*dy+dz*dz) + 1e-6)
                local dnx, dny, dnz = dx*invd, dy*invd, dz*invd
                local dot = (vnx*dnx + vny*dny + vnz*dnz)
                if dot > 0.6 then pd.state = STATE.RUSHING end
            end
        end
    end

    pd.last_update_time = now
    return pd
end

-- ─────────────────────────────── Offset calculation ───────────────────────────────
local function calc_optimal_offset(ent, st)
    local pd = player_data[ent]
    if not pd then return 0 end

    -- manual override if auto-learning off
    if not ui.get(ui_root.auto_learn) then
        if st == STATE.AIR and ui.get(ui_root.air_state) then return ui.get(ui_root.air_offs) end
        if (st == STATE.CROUCHING or st == STATE.CROUCH_MOVING) and ui.get(ui_root.crouch_state) then return ui.get(ui_root.crouch_offs) end
        if st == STATE.RUSHING and ui.get(ui_root.rush_state) then return ui.get(ui_root.rush_offs) end
    end

    local base = pd.optimal_offsets[st] or 0

    -- animlayer micro-adjust (Angel trick)
    if st == STATE.STANDING or st == STATE.CROUCHING then
        local lyr = pd.animation_layers[6] or pd.animation_layers[3]
        if lyr and lyr.playback_rate then
            local s = tostring(lyr.playback_rate)
            local d1 = tonumber(s:sub(1,1))
            local d2 = tonumber(s:sub(2,2))
            if d1 and d2 then
                local delta = math.abs((d1*10 + d2) - (d2*10 + d1))
                if delta > 0 then
                    local scale = (st == STATE.STANDING) and 1.6 or 1.2
                    base = clamp(-delta * scale, -60, 60)
                end
            end
        end
    end

    -- prefer last successful for same state
    local h = resolve_hist[ent]
    if h and h.hits_by_state[st] and h.hits_by_state[st] > 0 and #h.successful_yaws > 0 then
        for i=#h.successful_yaws,1,-1 do
            local it = h.successful_yaws[i]
            if it.state == st then base = it.offset break end
        end
    end

    return base
end

-- ─────────────────────────────── Resolver core ───────────────────────────────
local function resolve_player(ent)
    local pd = get_state(ent)
    if pd.state == STATE.INVALID then return end

    local prog = init_prog(ent)
    local now = globals.realtime()
    local dt = now - prog.last_update

    -- progress gain scales with state + history confidence
    local state_scale = (pd.state == STATE.STANDING and 2.0)
                      or (pd.state == STATE.AIR and 1.5)
                      or (pd.state == STATE.RUSHING and 0.8)
                      or 1.0
    local h = resolve_hist[ent]
    local conf = 1.0
    if h then
        local total = h.hits + h.misses
        if total > 0 then conf = 0.8 + (h.hits/total) end
    end
    prog.progress = math.min(100, prog.progress + (24 * dt) * state_scale * conf)
    if     prog.progress < 25 then prog.stage = 1
    elseif prog.progress < 50 then prog.stage = 2
    elseif prog.progress < 75 then prog.stage = 3
    else  prog.stage = 4; prog.is_resolved = true end

    local base_off = calc_optimal_offset(ent, pd.state)

    -- anti-bruteforce sequencing over misses
    local bs = init_brute(ent)
    local br_off = base_off
    if ui.get(ui_root.anti_brute) then
        local extend = ui.get(ui_root.brute_boost) or 0
        local sign = pd.desync_side ~= 0 and pd.desync_side or 1
        local mode = bs.seq[bs.idx] or 1
        if mode == 1 then        -- +base
            br_off = base_off
        elseif mode == 2 then    -- -base
            br_off = -base_off
        elseif mode == 3 then    -- extended to push a side
            local ext = sign * extend
            br_off = base_off + ext
        end
        br_off = clamp(br_off, -60, 60)
    end

    -- blend towards target offset as progress grows (defensive -> assertive)
    local f = prog.progress / 100
    local final_yaw = pd.lby_yaw + br_off * f

    plist.set(ent, "Correction Active", true)
    plist.set(ent, "Force Body Yaw", true)
    plist.set(ent, "Force Body Yaw Value", final_yaw)

    -- extreme pitch handling
    if pd.aim.pitch < -89 or pd.aim.pitch > 89 then
        plist.set(ent, "Force Pitch", true)
        plist.set(ent, "Force Pitch Value", 0)
    else
        plist.set(ent, "Force Pitch", false)
    end

    resolve_view[ent] = {
        yaw = final_yaw, offset = br_off, base_offset = base_off, brute_idx = bs.idx,
        side = pd.desync_side, state = pd.state, state_name = STATE_NAME[pd.state],
        progress = prog.progress, stage = prog.stage, is_resolved = prog.is_resolved
    }
    prog.last_update = now
    resolve_prog[ent] = prog
end

-- ─────────────────────────────── Learning updates ───────────────────────────────
local function update_learning(ent, hit, headshot)
    local pd = player_data[ent]; local h = init_hist(ent); local rv = resolve_view[ent]
    if not pd or not rv then return end
    local st = pd.state
    local off = rv.base_offset or rv.offset
    h.total_shots = h.total_shots + 1

    -- learning speed scale
    local ls = (ui.get(ui_root.learn_spd) or 40) / 100
    local k_hit  = 0.2 + 0.3 * ls
    local k_miss = 0.1 + 0.2 * ls

    if hit then
        h.hits = h.hits + 1
        h.hits_by_state[st] = (h.hits_by_state[st] or 0) + 1
        table.insert(h.successful_yaws, {yaw = rv.yaw, offset = off, state = st, time = globals.realtime(), headshot = headshot})
        h.resolve_confidence = math.min(100, h.resolve_confidence + (headshot and 8 or 4))
        pd.weights[st] = pd.weights[st] + (headshot and 2 or 1)
        pd.optimal_offsets[st] = pd.optimal_offsets[st] * (1 - k_hit) + off * k_hit

        -- reset bruteforce on success
        local bs = init_brute(ent)
        bs.idx, bs.consecutive_misses = 1, 0
    else
        h.misses = h.misses + 1
        h.misses_by_state[st] = (h.misses_by_state[st] or 0) + 1
        table.insert(h.failed_yaws, {yaw = rv.yaw, offset = off, state = st, time = globals.realtime()})
        h.resolve_confidence = math.max(0, h.resolve_confidence - 6)
        local penalty = -off * 0.6
        pd.optimal_offsets[st] = pd.optimal_offsets[st] * (1 - k_miss) + penalty * k_miss

        -- step bruteforce cycle
        local bs = init_brute(ent)
        bs.consecutive_misses = bs.consecutive_misses + 1
        bs.idx = (bs.idx % #bs.seq) + 1
    end

    while #h.successful_yaws > 32 do table.remove(h.successful_yaws, 1) end
    while #h.failed_yaws > 32 do table.remove(h.failed_yaws, 1) end

    resolve_hist[ent] = h
    player_data[ent] = pd
end

client.set_event_callback("player_hurt", function(e)
    if not ui.get(ui_root.enable) then return end
    local attacker = client.userid_to_entindex(e.attacker)
    local victim   = client.userid_to_entindex(e.userid)
    if not attacker or not victim then return end
    if attacker ~= entity.get_local_player() then return end
    local head = (e.hitgroup == 1)
    update_learning(victim, true, head)
    if ui.get(ui_root.debug_logs) then
        local rv = resolve_view[victim]
        client.color_log(160, 255, 80, string.format("[Copilot] Hit %s (%s) for %d (Stage %d/4, State %s)",
            entity.get_player_name(victim), head and "head" or "body", e.dmg_health,
            rv and rv.stage or 0, rv and rv.state_name or "UNKNOWN"))
    end
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(ui_root.enable) then return end
    local target = e.target
    if not target then return end
    update_learning(target, false, false)
    if ui.get(ui_root.debug_logs) then
        local rv = resolve_view[target]
        client.color_log(255, 120, 90, string.format("[Copilot] Missed %s due to %s (Stage %d/4, State %s)",
            entity.get_player_name(target), e.reason, rv and rv.stage or 0, rv and rv.state_name or "UNKNOWN"))
    end
end)

-- bullet_impact heuristic: penalize far-off line-to-head shots (Angel-inspired)
client.set_event_callback("bullet_impact", function(e)
    if not ui.get(ui_root.enable) then return end
    if not ui.get(ui_root.auto_learn) then return end
    local me = client.userid_to_entindex(e.userid)
    if not me or me ~= entity.get_local_player() then return end

    local ix,iy,iz = e.x, e.y, e.z
    local mx,my,mz = entity.get_origin(me)
    if not mx then return end
    local dirx, diry, dirz = ix - mx, iy - my, iz - mz
    local mag = math.sqrt(dirx*dirx + diry*diry + dirz*dirz)
    if mag < 1 then return end
    dirx, diry, dirz = dirx/mag, diry/mag, dirz/mag

    local best_err = 1e9
    local best_ent = nil
    for _, enemy in ipairs(entity.get_players(true)) do
        local hx,hy,hz = entity.hitbox_position(enemy, 0)
        if hx then
            local vx, vy, vz = hx - mx, hy - my, hz - mz
            local t = (vx*dirx + vy*diry + vz*dirz)
            if t > 0 then
                local px, py, pz = mx + dirx*t, my + diry*t, mz + dirz*t
                local dx, dy, dz = px - hx, py - hy, pz - hz
                local err = math.sqrt(dx*dx + dy*dy + dz*dz)
                if err < best_err then best_err, best_ent = err, enemy end
            end
        end
    end
    if best_ent and best_err > 8 then update_learning(best_ent, false, false) end
end)

-- ─────────────────────────────── Tick resolve ───────────────────────────────
client.set_event_callback("net_update_end", function()
    if not ui.get(ui_root.enable) then return end
    if ui.get(ui_root.fast_upd) then
        local step = math.max(1, ui.get(ui_root.upd_rate))
        if (globals.tickcount() % step) ~= 0 then return end
    end
    for _, enemy in ipairs(entity.get_players(true)) do
        resolve_player(enemy)
    end
end)

-- ─────────────────────────────── Visuals ───────────────────────────────
local function draw_visuals()
    if not ui.get(ui_root.enable) or not ui.get(ui_root.visualize) then return end
    local me = entity.get_local_player()
    if not me then return end

    local r,g,b,a = ui.get(cp_color)
    for _, enemy in ipairs(entity.get_players(true)) do
        local rv = resolve_view[enemy]
        if rv then
            local hx,hy,hz = entity.hitbox_position(enemy, 0)
            local ex,ey,ez = entity.get_origin(enemy)
            if hx and ex then
                local sh = { renderer.world_to_screen(hx, hy, hz) }
                local so = { renderer.world_to_screen(ex, ey, ez + 20) }
                if sh[1] and so[1] then
                    renderer.line(so[1], so[2], sh[1], sh[2], r, g, b, 180)
                    local yaw_rad = math.rad(rv.yaw)
                    local dx, dy = math.cos(yaw_rad)*18, math.sin(yaw_rad)*18
                    renderer.line(so[1], so[2], so[1] + dx, so[2] + dy, r, g, b, 200)

                    local label = rv.is_resolved and "RESOLVED" or string.format("Resolving %d%%", math.floor(rv.progress))
                    renderer.text(sh[1], sh[2] - 18, r, g, b, 240, "c", 0, label)
                    renderer.text(sh[1], sh[2] - 32, 255, 255, 255, 200, "c", 0, rv.state_name)
                    renderer.text(sh[1], sh[2] - 46, 200, 200, 200, 180, "c", 0, string.format("IDX %d | OFF %.1f", rv.brute_idx or 1, rv.offset or 0))
                end
            end
        end
    end

    if ui.get(ui_root.pred) then
        local strength = (ui.get(ui_root.pred_str) or 40)/100
        for _, enemy in ipairs(entity.get_players(true)) do
            local pd = player_data[enemy]
            if pd and pd.velocity then
                local ex,ey,ez = entity.get_origin(enemy)
                if ex then
                    local px = ex + pd.velocity.x * 0.02 * strength
                    local py = ey + pd.velocity.y * 0.02 * strength
                    local pz = ez + pd.velocity.z * 0.02 * strength
                    local ps = { renderer.world_to_screen(px, py, pz) }
                    if ps[1] then renderer.circle_outline(ps[1], ps[2], r, g, b, 180, 0, 0, 0, 1) end
                end
            end
        end
    end
end
client.set_event_callback("paint", draw_visuals)

-- ESP flags
client.register_esp_flag("RES", 150, 220, 255, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local rv = resolve_view[ent]
    if rv and not rv.is_resolved then return string.format("%d/4", rv.stage) end
    return false
end)
client.register_esp_flag("MTRX", 120, 190, 255, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local rv = resolve_view[ent]
    return rv and rv.is_resolved
end)
client.register_esp_flag("R", 255, 120, 120, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local rv = resolve_view[ent]
    return rv and rv.side == 1
end)
client.register_esp_flag("L", 120, 200, 120, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local rv = resolve_view[ent]
    return rv and rv.side == -1
end)
client.register_esp_flag("AIR", 120, 180, 255, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local pd = player_data[ent]
    return pd and (pd.state == STATE.AIR or pd.state == STATE.AIR_CROUCH)
end)
client.register_esp_flag("CROUCH", 220, 220, 120, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local pd = player_data[ent]
    return pd and (pd.state == STATE.CROUCHING or pd.state == STATE.CROUCH_MOVING)
end)
client.register_esp_flag("RUSH", 255, 160, 80, function(ent)
    if not ui.get(ui_root.enable) or not ui.get(ui_root.esp_flags) then return false end
    local pd = player_data[ent]
    return pd and (pd.state == STATE.RUSHING)
end)

-- Titles
client.set_event_callback("paint_ui", function()
    ui.set(ui_root.title, "Copilot Resolver")
    ui.set(ui_root.state_title, "-=- State analysis -=-")
    ui.set(ui_root.perf_title, "Performance")
    ui.set(ui_root.credits, "Copilot Resolver | Vector/Animlayer-inspired")
end)

-- Cleanup
client.set_event_callback("shutdown", function()
    ui.set_visible(plist_refs.ForceBody, true)
    ui.set_visible(plist_refs.CorrActive, true)
    ui.set(plist_refs.ResetAll, true)
end)

client.color_log(120, 200, 255, "[Copilot] Resolver loaded. Learning, anti-bruteforce, and state-aware yaw control active.")



-- Visual Indicator
local function safe_get(ref)
    return (ref and ui.get(ref)) or false
end

local function get_active_mode()
    if safe_get(resolver_default)     then return "Default" end
    if safe_get(resolver_aggressive)  then return "Aggressive" end
    if safe_get(resolver_experimental)then return "Experimental" end
    return "Off"
end

client.set_event_callback("paint", function()
    local mode = get_active_mode()
    if mode == "Off" then return end
    local color = mode_colors[mode] or {255, 255, 255}
    local sw, sh = client.screen_size()
    renderer.text(sw - 200, sh - 40, color[1], color[2], color[3], 255, "c", 0, "Resolver: " .. mode)
end)



-- Dependencies
local enemies = {}
local resolver_modes_list = {"Default", "Aggressive", "Experimental"}
local mode_colors = {
    Default = {255, 255, 255},
    Aggressive = {255, 100, 100},
    Experimental = {100, 200, 255}
}

-- UI
local resolver_enabled = ui.new_checkbox("Rage", "Other", "Enable per-enemy resolver")
local brute_extend = ui.new_slider("Rage", "Other", "Brute extend (deg)", 0, 60, 20)

-- Resolver State
local function init_enemy(entindex)
    if enemies[entindex] then return end
    enemies[entindex] = {
        mode_index = 1,
        last_result = "none"
    }
end

-- Resolver Cycle
local function cycle_mode(entindex, hit)
    if not enemies[entindex] then return end
    if hit then
        enemies[entindex].mode_index = 1
        enemies[entindex].last_result = "hit"
    else
        enemies[entindex].mode_index = (enemies[entindex].mode_index % #resolver_modes_list) + 1
        enemies[entindex].last_result = "miss"
    end
end

-- Resolver Logic Hook
client.set_event_callback("aim_hit", function(e)
    if not ui.get(resolver_enabled) then return end
    local target = client.userid_to_entindex(e.userid)
    init_enemy(target)
    cycle_mode(target, true)
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(resolver_enabled) then return end
    local target = client.userid_to_entindex(e.userid)
    init_enemy(target)
    cycle_mode(target, false)
end)

-- Visual Indicator
client.set_event_callback("paint", function()
    if not ui.get(resolver_enabled) then return end
    for _, entindex in pairs(entity.get_players(true)) do
        init_enemy(entindex)
        local x, y, z = entity.get_origin(entindex)
        local sx, sy = renderer.world_to_screen(x, y, z + 85)
        if sx and sy then
            local mode = resolver_modes_list[enemies[entindex].mode_index]
            local color = mode_colors[mode]
            local result = enemies[entindex].last_result
            local suffix = result == "hit" and "✓" or result == "miss" and "✗" or ""
            renderer.text(sx, sy, color[1], color[2], color[3], 255, "c", 0, mode .. " " .. suffix)
        end
    end
end)
-- Resolver controls
local resolver_default     = ui.new_checkbox("Rage", "Other", "Resolver: Default")
local key_default          = ui.new_hotkey("Rage", "Other", "Default resolver key", true)

local resolver_aggressive  = ui.new_checkbox("Rage", "Other", "Resolver: Aggressive")
local key_aggressive       = ui.new_hotkey("Rage", "Other", "Aggressive resolver key", true)

local resolver_experimental = ui.new_checkbox("Rage", "Other", "Resolver: Experimental")
local key_experimental      = ui.new_hotkey("Rage", "Other", "Experimental resolver key", true)

-- Hotkey toggle logic for all three
client.set_event_callback("run_command", function()
    ui.set(resolver_default,     ui.get(key_default))
    ui.set(resolver_aggressive,  ui.get(key_aggressive))
    ui.set(resolver_experimental,ui.get(key_experimental))
end)

-- Mutually exclusive hotkey logic
client.set_event_callback("run_command", function()
    if ui.get(key_default) then
        ui.set(resolver_default, true)
        ui.set(resolver_aggressive, false)
        ui.set(resolver_experimental, false)
        return
    end

    if ui.get(key_aggressive) then
        ui.set(resolver_default, false)
        ui.set(resolver_aggressive, true)
        ui.set(resolver_experimental, false)
        return
    end

    if ui.get(key_experimental) then
        ui.set(resolver_default, false)
        ui.set(resolver_aggressive, false)
        ui.set(resolver_experimental, true)
        return
    end

    -- If no key held, all disabled
    ui.set(resolver_default, false)
    ui.set(resolver_aggressive, false)
    ui.set(resolver_experimental, false)
end)

-- Resolver: BAIM-if-lethal module (global override across all resolver modes)

-- References to Ragebot body-aim controls
local prefer_baim, prefer_baim_key = ui.reference("RAGE", "Aimbot", "Prefer body aim")
local force_baim,  force_baim_key  = ui.reference("RAGE", "Aimbot", "Force body aim")

-- Module UI (placed with your other resolver controls)
local baim_if_lethal   = ui.new_checkbox("Rage", "Other", "Enable BAIM if lethal")
local lethal_hitbox    = ui.new_combobox("Rage", "Other", "Lethal check hitbox", {"Pelvis", "Stomach", "Chest", "Any body"})
local lethal_hp_buffer = ui.new_slider("Rage", "Other", "Lethal HP buffer", 0, 70, 0, "hp")

-- Defaults
ui.set(lethal_hitbox, "Any body")
ui.set(lethal_hp_buffer, 0)

-- Show/hide children based on master checkbox
local function set_children_visibility()
    local on = ui.get(baim_if_lethal)
    ui.set_visible(lethal_hitbox, on)
    ui.set_visible(lethal_hp_buffer, on)
end
set_children_visibility()
ui.set_callback(baim_if_lethal, set_children_visibility)

-- Internal state
local forced_by_module = false
local user_force_snapshot = nil

local function get_body_hitboxes(mode)
    if mode == "Pelvis" then
        return {2}
    elseif mode == "Stomach" then
        return {3}
    elseif mode == "Chest" then
        return {4, 5, 6}
    else
        return {2, 3, 4, 5, 6}
    end
end

-- Core: decide and apply BAIM force
client.set_event_callback("run_command", function()
    if not ui.get(baim_if_lethal) then
        if forced_by_module then
            ui.set(force_baim, user_force_snapshot or false)
            forced_by_module, user_force_snapshot = false, nil
        end
        return
    end

    local me = entity.get_local_player()
    if not me or me == 0 or not entity.is_alive(me) then
        if forced_by_module then
            ui.set(force_baim, user_force_snapshot or false)
            forced_by_module, user_force_snapshot = false, nil
        end
        return
    end

    local ex, ey, ez = client.eye_position()
    if not ex then return end

    local hb_mode = ui.get(lethal_hitbox)
    local hb_list = get_body_hitboxes(hb_mode)
    local buffer  = ui.get(lethal_hp_buffer)

    local enemies = entity.get_players(true)
    local lethal_found = false

    for i=1, #enemies do
        local e = enemies[i]
        if e ~= nil and entity.is_alive(e) and not entity.is_dormant(e) then
            local hp = entity.get_prop(e, "m_iHealth") or 0
            if hp > 0 then
                for _, hb in ipairs(hb_list) do
                    local hx, hy, hz = entity.hitbox_position(e, hb)
                    if hx then
                        local ent_hit, dmg = client.trace_bullet(me, ex, ey, ez, hx, hy, hz)
                        if ent_hit == e and dmg and dmg >= (hp - buffer) then
                            lethal_found = true
                            break
                        end
                    end
                end
            end
        end
        if lethal_found then break end
    end

    if lethal_found then
        if not forced_by_module then
            user_force_snapshot = ui.get(force_baim)
            forced_by_module = true
        end
        ui.set(force_baim, true)
    else
        if forced_by_module then
            ui.set(force_baim, user_force_snapshot or false)
            forced_by_module, user_force_snapshot = false, nil
        end
    end
end)
-- ─────────────────────────────── Autosniper enhancer: prediction, DT control, 62‑tick BT, BT resolver ───────────────────────────────
-- Scope: Rage autosnipers (SCAR‑20/G3SG1). Adds lead prediction overlay, dt speed control, 62‑tick backtrack buffer,
-- and a backtrack-aware resolver decision on autosniper shots.

-- UI
local asn_enable        = ui.new_checkbox("Rage", "Other", "Autosniper enhancer")
local asn_pred          = ui.new_checkbox("Rage", "Other", "ASN: prediction overlay")
local asn_pred_strength = ui.new_slider("Rage", "Other", "ASN: prediction strength", 0, 100, 45, true, "%")
local asn_bt_enable     = ui.new_checkbox("Rage", "Other", "ASN: backtrack resolver")
local asn_bt_ticks      = ui.new_slider("Rage", "Other", "ASN: backtrack ticks", 1, 62, 62, true, "t")
local asn_dt_enable     = ui.new_checkbox("Rage", "Other", "ASN: DT tune")
local asn_dt_speed      = ui.new_slider("Rage", "Other", "ASN: DT speed (%)", 50, 120, 100, true, "%")

-- Visibility
local function asn_vis()
    local on = ui.get(asn_enable)
    ui.set_visible(asn_pred, on)
    ui.set_visible(asn_pred_strength, on and ui.get(asn_pred))
    ui.set_visible(asn_bt_enable, on)
    ui.set_visible(asn_bt_ticks, on and ui.get(asn_bt_enable))
    ui.set_visible(asn_dt_enable, on)
    ui.set_visible(asn_dt_speed, on and ui.get(asn_dt_enable))
end
ui.set_callback(asn_enable, asn_vis)
ui.set_callback(asn_pred, asn_vis)
ui.set_callback(asn_bt_enable, asn_vis)
ui.set_callback(asn_dt_enable, asn_vis)
asn_vis()

-- Helpers
local function is_autosniper(ent)
    local w = entity.get_player_weapon(ent); if not w then return false end
    local cls = entity.get_classname(w)
    return cls == "CWeaponSCAR20" or cls == "CWeaponG3SG1"
end

local function vec_len2(x,y) return math.sqrt(x*x + y*y) end
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function lerp(a, b, t) return a + (b-a) * t end

-- DT references (robust across builds)
local function ref_try(a,b,c)
    local ok, r1, r2, r3 = pcall(ui.reference, a,b,c)
    if ok then return r1, r2, r3 end
end

local dt_ref_cat = { {"Rage","Other"}, {"Rage","Exploits"} }
local dt_names   = {
    speed     = {"Double tap speed","Double tap quick recharge"},
    toggle    = {"Double tap"},
    shift     = {"Shift amount"},
    tol       = {"Tolerance"},
    recharge  = {"Minimum recharge"},
    mode      = {"Double tap mode"}
}

local DT = {}
do
    for _, cat in ipairs(dt_ref_cat) do
        if not DT.toggle then
            DT.toggle, DT.key = ref_try(cat[1],cat[2],dt_names.toggle[1])
        end
        if not DT.speed then
            DT.speed = select(1, ref_try(cat[1],cat[2],dt_names.speed[1])) or select(1, ref_try(cat[1],cat[2],dt_names.speed[2]))
        end
        if not DT.shift then DT.shift = select(1, ref_try(cat[1],cat[2],dt_names.shift[1])) end
        if not DT.tol   then DT.tol   = select(1, ref_try(cat[1],cat[2],dt_names.tol[1]))   end
        if not DT.rec   then DT.rec   = select(1, ref_try(cat[1],cat[2],dt_names.recharge[1])) end
        if not DT.mode  then DT.mode  = select(1, ref_try(cat[1],cat[2],dt_names.mode[1]))  end
    end
end

-- Apply DT speed tuning (when enabled and using autosniper)
client.set_event_callback("run_command", function()
    if not ui.get(asn_enable) or not ui.get(asn_dt_enable) then return end
    local me = entity.get_local_player(); if not me or not is_autosniper(me) then return end

    local pct = (ui.get(asn_dt_speed) or 100) / 100
    -- Conservative defaults; if sliders exist we scale towards aggressive but within sane bounds.
    if DT.speed and ui.type(DT.speed) == "slider" then
        local mn, mx = 1, 100
        local base = 100
        ui.set(DT.speed, clamp(math.floor(base * pct), mn, mx))
    end
    if DT.shift and ui.type(DT.shift) == "slider" then
        local mn, mx = 10, 20 -- typical shift range
        ui.set(DT.shift, clamp(math.floor(16 * pct), mn, mx))
    end
    if DT.tol and ui.type(DT.tol) == "slider" then
        local mn, mx = 0, 10
        ui.set(DT.tol, clamp(math.floor(4 * (2 - pct)), mn, mx)) -- faster dt => lower tolerance
    end
    if DT.rec and ui.type(DT.rec) == "slider" then
        local mn, mx = 0, 16
        ui.set(DT.rec, clamp(math.floor(8 * (2 - pct)), mn, mx)) -- faster dt => lower min recharge
    end
end)

-- Backtrack records (up to 62 ticks)
local TICK = { interval = globals.tickinterval() }
local function time_to_ticks(t) return math.floor(0.5 + t / TICK.interval) end

local BT = {} -- [ent] = { {sim, head={x,y,z}, org={x,y,z}, vel={x,y,z}, flags=... , tick=...}, ... }
local MAX_T = 62

client.set_event_callback("net_update_end", function()
    if not ui.get(asn_enable) then return end
    local me = entity.get_local_player(); if not me then return end
    local enemies = entity.get_players(true)
    for i=1, #enemies do
        local e = enemies[i]
        local sim = entity.get_prop(e, "m_flSimulationTime") or globals.curtime()
        local hx,hy,hz = entity.hitbox_position(e, 0)
        local ox,oy,oz = entity.get_origin(e)
        local vx = entity.get_prop(e, "m_vecVelocity[0]") or 0
        local vy = entity.get_prop(e, "m_vecVelocity[1]") or 0
        local vz = entity.get_prop(e, "m_vecVelocity[2]") or 0

        if hx and ox then
            BT[e] = BT[e] or {}
            table.insert(BT[e], 1, {
                sim = sim,
                head = {hx,hy,hz},
                org  = {ox,oy,oz},
                vel  = {vx,vy,vz},
                tick = globals.tickcount()
            })
            while #BT[e] > (ui.get(asn_bt_ticks) or MAX_T) do table.remove(BT[e]) end
        end
    end
end)

-- Backtrack resolver selection (autosniper)
local function pick_bt_record(ent)
    if not BT[ent] or #BT[ent] == 0 then return nil end
    -- Heuristic: prefer recent record where target is decelerating or stopped and where aim line is clean.
    local best, best_score = nil, -1e9
    local me = entity.get_local_player(); local ex,ey,ez = client.eye_position()
    for i=1, #BT[ent] do
        local r = BT[ent][i]
        -- decel factor (prefer low speed)
        local spd = vec_len2(r.vel[1], r.vel[2])
        local decel_score = 200 - clamp(spd, 0, 200)
        -- visibility/line cleanliness
        local hit, dmg = client.trace_bullet(me, ex, ey, ez, r.head[1], r.head[2], r.head[3])
        local vis_score = (hit == ent) and 50 or -25
        -- age penalty
        local age = i - 1
        local age_score = -age * 2
        local score = decel_score + vis_score + age_score
        if score > best_score then best, best_score = r, score end
    end
    return best
end

-- If you use the resolver_view from earlier code, we can bias yaw with the chosen record’s movement side.
local function apply_bt_resolver(ent, rec)
    if not rec then return end
    -- Minimal side hint: rightward movement => prefer right; leftward => prefer left
    local side = (rec.vel[1] ~= 0 or rec.vel[2] ~= 0) and ((rec.vel[1] + rec.vel[2]) > 0 and 1 or -1) or 0
    if plist and plist.set then
        plist.set(ent, "Correction Active", true)
        if side ~= 0 then
            plist.set(ent, "Force Body Yaw", true)
            -- Nudge body yaw side 25 deg towards movement side, non-destructive.
            local yaw = entity.get_prop(ent, "m_flLowerBodyYawTarget") or 0
            plist.set(ent, "Force Body Yaw Value", yaw + side * 25)
        end
    end
end

-- On autosniper shot preparation, pick a BT record and bias resolver
client.set_event_callback("aim_fire", function(e)
    if not ui.get(asn_enable) or not ui.get(asn_bt_enable) then return end
    local me = entity.get_local_player(); if not me or not is_autosniper(me) then return end
    local target = e.target; if not target then return end
    local rec = pick_bt_record(target)
    apply_bt_resolver(target, rec)
end)

-- Prediction overlay for autosniper (lead target by velocity * strength)
client.set_event_callback("paint", function()
    if not ui.get(asn_enable) or not ui.get(asn_pred) then return end
    local me = entity.get_local_player(); if not me or not is_autosniper(me) then return end

    local strength = (ui.get(asn_pred_strength) or 45) / 100
    for _, ent in ipairs(entity.get_players(true)) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local ox,oy,oz = entity.get_origin(ent)
            local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
            local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
            local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
            if ox then
                local lead_t = clamp(0.12 * strength, 0.02, 0.25) -- 20–250 ms lead
                local px = ox + vx * lead_t
                local py = oy + vy * lead_t
                local pz = oz + vz * lead_t
                local sx,sy = renderer.world_to_screen(ox,oy,oz+8)
                local pxs,pys = renderer.world_to_screen(px,py,pz+8)
                if sx and pxs then
                    renderer.line(sx,sy,pxs,pys, 160,230,255,180)
                    renderer.circle_outline(pxs,pys, 160,230,255,200, 0, 0, 0, 2)
                end
            end
        end
    end
end)


-- 🧠 DT Weapon-Specific Tuner + Scout Fakelag Restore + BT Resolver
local ui_new_checkbox = ui.new_checkbox
local ui_new_slider   = ui.new_slider
local ui_get          = ui.get
local ui_set          = ui.set
local entity_get_local_player = entity.get_local_player
local entity_get_player_weapon = entity.get_player_weapon
local entity_get_classname = entity.get_classname
local client_set_event_callback = client.set_event_callback
local ui_reference = ui.reference
local ui_type = ui.type

-- 🌐 UI Elements
local dt_enable        = ui_new_checkbox("Rage", "Other", "DT: Weapon-based tuning")
local dt_tolerance     = ui_new_slider("Rage", "Other", "DT: Tolerance", 0, 10, 2, true, "t")
local scout_fakelag    = ui_new_checkbox("Rage", "Other", "Scout: 0 fakelag on peek + restore")
local scout_bt_resolver= ui_new_checkbox("Rage", "Other", "Scout: BT resolver")

-- Per-weapon DT sliders
local dt_ticks = {
    ["CWeaponAWP"]     = ui_new_slider("Rage", "Other", "DT: AWP ticks", 0, 18, 16, true, "t"),
    ["CWeaponSSG08"]   = ui_new_slider("Rage", "Other", "DT: Scout ticks", 0, 18, 16, true, "t"),
    ["CWeaponElite"]   = ui_new_slider("Rage", "Other", "DT: Dualies ticks", 0, 18, 16, true, "t"),
    ["CWeaponAK47"]    = ui_new_slider("Rage", "Other", "DT: AK-47 ticks", 0, 18, 16, true, "t"),
    ["CWeaponG3SG1"]   = ui_new_slider("Rage", "Other", "DT: G3SG1 ticks", 0, 18, 16, true, "t"),
    ["CWeaponSCAR20"]  = ui_new_slider("Rage", "Other", "DT: SCAR-20 ticks", 0, 18, 16, true, "t"),
    ["CKnife"]         = ui_new_slider("Rage", "Other", "DT: Knife ticks", 0, 18, 16, true, "t"),
    ["CKnifeGG"]       = ui_new_slider("Rage", "Other", "DT: KnifeGG ticks", 0, 18, 16, true, "t"),
    ["CWeaponTaser"]   = ui_new_slider("Rage", "Other", "DT: Zeus ticks", 0, 18, 16, true, "t"),
}


-- 🕵️ Scout Peek Fakelag Override + Restore (hardened, multi-version, nil-safe)

-- state
local original_fakelag = nil
local applied_override = false

-- robust ui.reference caller (tries both ui.reference and ui_reference)
local function try_ref(path1, path2, label)
    local ok, a, b, c
    if ui and ui.reference then
        ok, a, b, c = pcall(ui.reference, path1, path2, label)
        if ok and a ~= nil then return a, b, c end
    end
    if _G.ui_reference then
        ok, a, b, c = pcall(_G.ui_reference, path1, path2, label)
        if ok and a ~= nil then return a, b, c end
    end
    return nil
end

-- multi-label resolver with lazy caching
local peek_ref, limit_ref
local function resolve_refs()
    if not peek_ref then
        peek_ref = select(1,
            try_ref("AA", "Fake lag", "Peek fake lag") or
            try_ref("AA", "Fake lag", "Peek fake-lag")
        )
    end
    if not limit_ref then
        limit_ref = select(1,
            try_ref("AA", "Fake lag", "Limit") or
            try_ref("AA", "Fake lag", "Fake lag limit")
        )
    end
end

-- safe ui getters/setters (use your existing aliases)
local function safe_get(ref)
    if not ref then return nil end
    local ok, val = pcall(ui_get, ref)
    return ok and val or nil
end

local function safe_set(ref, val)
    if not ref then return false end
    local ok = pcall(ui_set, ref, val)
    return ok
end

-- ensure we always restore cleanly
local function restore_limit()
    if applied_override and limit_ref and original_fakelag ~= nil then
        safe_set(limit_ref, original_fakelag)
    end
    original_fakelag = nil
    applied_override = false
end

client_set_event_callback("run_command", function()
    -- feature toggle
    if not scout_fakelag or not ui_get(scout_fakelag) then
        -- if user turned it off mid-round, restore if needed
        restore_limit()
        return
    end

    -- resolve refs lazily (handles UI changes/reloads)
    resolve_refs()
    if not peek_ref or not limit_ref then
        -- controls missing on this build; do nothing gracefully
        restore_limit()
        return
    end

    -- entity validation
    local me = entity_get_local_player(); if not me then restore_limit(); return end
    local weapon = entity_get_player_weapon(me); if not weapon then restore_limit(); return end
    local class = entity_get_classname(weapon)

    -- if we swapped off scout, restore immediately
    if class ~= "CWeaponSSG08" then
        restore_limit()
        return
    end

    -- read peek state
    local is_peeking = safe_get(peek_ref)
    if is_peeking == nil then
        -- peek control unreadable; bail safely
        restore_limit()
        return
    end

    -- apply / maintain / restore
    if is_peeking then
        if not applied_override then
            local cur = safe_get(limit_ref)
            if cur ~= nil then
                original_fakelag = cur
                -- most builds disallow 0; clamp to at least 1 to avoid range errors
                safe_set(limit_ref, 1)
                applied_override = true
            end
        end
    else
        restore_limit()
    end
end)

-- hard safety: restore on round transitions (if you already hook these, merge the restore)
client_set_event_callback("round_start", restore_limit)
client_set_event_callback("player_death", function(e)
    -- only care if we died
    local uid = e and e.userid
    if not uid or not client then return end
    local ent = client.userid_to_entindex(uid)
    if ent and ent == entity_get_local_player() then
        restore_limit()
    end
end)

-- ─────────────────────────────── Head Angle Logger ───────────────────────────────
-- Logs current target's head angles (pitch/yaw/LBY) with context.

-- UI
local hal_enable            = ui.new_checkbox("Rage", "Other", "Log head angles")
local hal_on_change         = ui.new_checkbox("Rage", "Other", "HAL: on target change")
local hal_on_shot           = ui.new_checkbox("Rage", "Other", "HAL: on shot")
local hal_on_hit            = ui.new_checkbox("Rage", "Other", "HAL: on hit")
local hal_on_miss           = ui.new_checkbox("Rage", "Other", "HAL: on miss")
local hal_color             = ui.new_color_picker("Rage", "Other", "HAL: log color", 160, 220, 255, 255)
local hal_fov_thresh        = ui.new_slider("Rage", "Other", "HAL: acquire FOV", 1, 30, 8, true, "°")

-- Visibility
local function hal_vis()
    local on = ui.get(hal_enable)
    ui.set_visible(hal_on_change, on)
    ui.set_visible(hal_on_shot, on)
    ui.set_visible(hal_on_hit, on)
    ui.set_visible(hal_on_miss, on)
    ui.set_visible(hal_color, on)
    ui.set_visible(hal_fov_thresh, on)
end
ui.set_callback(hal_enable, hal_vis)
hal_vis()

-- Math helpers
local function ang_norm(a) return (a + 180) % 360 - 180 end
local function ang_diff(a, b) return math.abs(ang_norm(a - b)) end

local function vec_to_angles(dx, dy, dz)
    local hyp = math.sqrt(dx*dx + dy*dy)
    local yaw = math.deg(math.atan2(dy, dx))
    local pitch = -math.deg(math.atan2(dz, hyp))
    return pitch, yaw
end

-- Acquire "current target" by smallest angular error to head within FOV
local function hal_current_target()
    local me = entity.get_local_player()
    if not me or not entity.is_alive(me) then return nil end

    local cam_p, cam_y = client.camera_angles()
    local ex, ey, ez = client.eye_position()
    if not cam_p or not ex then return nil end

    local best, best_err = nil, 1e9
    local enemies = entity.get_players(true)
    for i = 1, #enemies do
        local e = enemies[i]
        if entity.is_alive(e) and not entity.is_dormant(e) then
            local hx, hy, hz = entity.hitbox_position(e, 0)
            if hx then
                local dp, dyaw = vec_to_angles(hx - ex, hy - ey, hz - ez)
                local err = ang_diff(dyaw, cam_y) + 0.5 * ang_diff(dp, cam_p)
                if err < best_err then
                    best, best_err = e, err
                end
            end
        end
    end

    local fov = ui.get(hal_fov_thresh) or 8
    if best and best_err <= fov then
        return best
    end
    return nil
end

-- Angle fetch
local function hal_angles(ent)
    if not ent then return nil end
    local pitch, yaw = entity.get_prop(ent, "m_angEyeAngles")
    local lby = entity.get_prop(ent, "m_flLowerBodyYawTarget")
    return pitch or 0, yaw or 0, lby or 0
end

-- Logging
local hal_last_target = nil
local function hal_log(ent, ctx)
    if not ent then return end
    local p, y, lby = hal_angles(ent)
    local name = entity.get_player_name(ent) or ("ent#" .. tostring(ent))
    local r, g, b, _ = ui.get(hal_color)
    client.color_log(r, g, b, string.format("[HAL] %s | %s | pitch %.1f yaw %.1f lby %.1f", ctx, name, p, y, lby))
end

-- Target change logging (per-tick)
client.set_event_callback("run_command", function()
    if not ui.get(hal_enable) or not ui.get(hal_on_change) then return end
    local cur = hal_current_target()
    if cur ~= hal_last_target then
        hal_last_target = cur
        if cur then hal_log(cur, "target-change") end
    end
end)

-- Shot logging
client.set_event_callback("aim_fire", function(e)
    if not ui.get(hal_enable) or not ui.get(hal_on_shot) then return end
    local tgt = e and e.target
    if not tgt then
        tgt = hal_current_target()
    end
    if tgt then hal_log(tgt, "shot") end
end)

-- Hit logging
client.set_event_callback("aim_hit", function(e)
    if not ui.get(hal_enable) or not ui.get(hal_on_hit) then return end
    local tgt = e and e.target
    if not tgt and e and e.userid then
        tgt = client.userid_to_entindex(e.userid)
    end
    if tgt then hal_log(tgt, "hit") end
end)

-- Miss logging
client.set_event_callback("aim_miss", function(e)
    if not ui.get(hal_enable) or not ui.get(hal_on_miss) then return end
    local tgt = e and e.target
    if tgt then hal_log(tgt, "miss:" .. (e.reason or "unknown")) end
end)

-- Clean up on shutdown
client.set_event_callback("shutdown", function()
    hal_last_target = nil
end)

-- 🎯 Scout BT Resolver
client_set_event_callback("aim_fire", function(e)
    if not ui_get(scout_bt_resolver) then return end
    local me = entity_get_local_player(); if not me then return end
    local weapon = entity_get_player_weapon(me); if not weapon then return end
    local class = entity_get_classname(weapon); if class ~= "CWeaponSSG08" then return end

    local target = e.target; if not target then return end
    local yaw = entity.get_prop(target, "m_angEyeAngles[1]") or 0
    local pitch = entity.get_prop(target, "m_angEyeAngles[0]") or 0

    -- Example: aggressive yaw correction
    local resolved_yaw = (yaw + 180) % 360
    local resolved_pitch = math.max(-89, math.min(89, pitch))

    -- Apply resolver logic (replace with your resolver API if needed)
    -- resolver.set_angle(target, resolved_pitch, resolved_yaw)
end)


-- Backtrack records (up to 62 ticks)
local TICK = { interval = globals.tickinterval() }
local function time_to_ticks(t) return math.floor(0.5 + t / TICK.interval) end

local BT = {} -- [ent] = { {sim, head={x,y,z}, org={x,y,z}, vel={x,y,z}, flags=... , tick=...}, ... }
local MAX_T = 62

client.set_event_callback("net_update_end", function()
    if not ui.get(asn_enable) then return end
    local me = entity.get_local_player(); if not me then return end
    local enemies = entity.get_players(true)
    for i=1, #enemies do
        local e = enemies[i]
        local sim = entity.get_prop(e, "m_flSimulationTime") or globals.curtime()
        local hx,hy,hz = entity.hitbox_position(e, 0)
        local ox,oy,oz = entity.get_origin(e)
        local vx = entity.get_prop(e, "m_vecVelocity[0]") or 0
        local vy = entity.get_prop(e, "m_vecVelocity[1]") or 0
        local vz = entity.get_prop(e, "m_vecVelocity[2]") or 0

        if hx and ox then
            BT[e] = BT[e] or {}
            table.insert(BT[e], 1, {
                sim = sim,
                head = {hx,hy,hz},
                org  = {ox,oy,oz},
                vel  = {vx,vy,vz},
                tick = globals.tickcount()
            })
            while #BT[e] > (ui.get(asn_bt_ticks) or MAX_T) do table.remove(BT[e]) end
        end
    end
end)

-- Backtrack resolver selection (autosniper)
local function pick_bt_record(ent)
    if not BT[ent] or #BT[ent] == 0 then return nil end
    -- Heuristic: prefer recent record where target is decelerating or stopped and where aim line is clean.
    local best, best_score = nil, -1e9
    local me = entity.get_local_player(); local ex,ey,ez = client.eye_position()
    for i=1, #BT[ent] do
        local r = BT[ent][i]
        -- decel factor (prefer low speed)
        local spd = vec_len2(r.vel[1], r.vel[2])
        local decel_score = 200 - clamp(spd, 0, 200)
        -- visibility/line cleanliness
        local hit, dmg = client.trace_bullet(me, ex, ey, ez, r.head[1], r.head[2], r.head[3])
        local vis_score = (hit == ent) and 50 or -25
        -- age penalty
        local age = i - 1
        local age_score = -age * 2
        local score = decel_score + vis_score + age_score
        if score > best_score then best, best_score = r, score end
    end
    return best
end

-- If you use the resolver_view from earlier code, we can bias yaw with the chosen record’s movement side.
local function apply_bt_resolver(ent, rec)
    if not rec then return end
    -- Minimal side hint: rightward movement => prefer right; leftward => prefer left
    local side = (rec.vel[1] ~= 0 or rec.vel[2] ~= 0) and ((rec.vel[1] + rec.vel[2]) > 0 and 1 or -1) or 0
    if plist and plist.set then
        plist.set(ent, "Correction Active", true)
        if side ~= 0 then
            plist.set(ent, "Force Body Yaw", true)
            -- Nudge body yaw side 25 deg towards movement side, non-destructive.
            local yaw = entity.get_prop(ent, "m_flLowerBodyYawTarget") or 0
            plist.set(ent, "Force Body Yaw Value", yaw + side * 25)
        end
    end
end

-- On autosniper shot preparation, pick a BT record and bias resolver
client.set_event_callback("aim_fire", function(e)
    if not ui.get(asn_enable) or not ui.get(asn_bt_enable) then return end
    local me = entity.get_local_player(); if not me or not is_autosniper(me) then return end
    local target = e.target; if not target then return end
    local rec = pick_bt_record(target)
    apply_bt_resolver(target, rec)
end)

-- Prediction overlay for autosniper (lead target by velocity * strength)
client.set_event_callback("paint", function()
    if not ui.get(asn_enable) or not ui.get(asn_pred) then return end
    local me = entity.get_local_player(); if not me or not is_autosniper(me) then return end

    local strength = (ui.get(asn_pred_strength) or 45) / 100
    for _, ent in ipairs(entity.get_players(true)) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local ox,oy,oz = entity.get_origin(ent)
            local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
            local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
            local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
            if ox then
                local lead_t = clamp(0.12 * strength, 0.02, 0.25) -- 20–250 ms lead
                local px = ox + vx * lead_t
                local py = oy + vy * lead_t
                local pz = oz + vz * lead_t
                local sx,sy = renderer.world_to_screen(ox,oy,oz+8)
                local pxs,pys = renderer.world_to_screen(px,py,pz+8)
                if sx and pxs then
                    renderer.line(sx,sy,pxs,pys, 160,230,255,180)
                    renderer.circle_outline(pxs,pys, 160,230,255,200, 0, 0, 0, 2)
                end
            end
        end
    end
end)

-- ─────────────────────────────── Resolver Stats Display (Above Center-Left) ───────────────────────────────
local resolver_stats_color = ui.new_color_picker("Rage", "Other", "Resolver stats color", 255, 255, 255, 255)

local resolver_stats = {
    Default = { hits = 0, misses = 0 },
    Aggressive = { hits = 0, misses = 0 },
    Experimental = { hits = 0, misses = 0 }
}

client.set_event_callback("aim_hit", function(e)
    local mode = ui.get(resolver_default) and "Default"
              or ui.get(resolver_aggressive) and "Aggressive"
              or ui.get(resolver_experimental) and "Experimental"
    if mode then
        resolver_stats[mode].hits = resolver_stats[mode].hits + 1
    end
end)

client.set_event_callback("aim_miss", function(e)
    local mode = ui.get(resolver_default) and "Default"
              or ui.get(resolver_aggressive) and "Aggressive"
              or ui.get(resolver_experimental) and "Experimental"
    if mode then
        resolver_stats[mode].misses = resolver_stats[mode].misses + 1
    end
end)

client.set_event_callback("paint", function()
    local r,g,b,a = ui.get(resolver_stats_color)
    local sw, sh = client.screen_size()
    local x = sw * 0.05
    local y = sh * 0.45

    for mode, stats in pairs(resolver_stats) do
        local text = string.format("%s: %d hits / %d misses", mode, stats.hits, stats.misses)
        renderer.text(x, y, r, g, b, a, "", 0, text)
        y = y + 16
    end
end)


-- UI
local clear_decals_enable = ui.new_checkbox("Rage", "Other", "Auto clear decals")
local clear_on_impact     = ui.new_checkbox("Rage", "Other", "Clear on bullet impact")
local clear_on_hurt       = ui.new_checkbox("Rage", "Other", "Clear on player hurt")
local clear_on_round      = ui.new_checkbox("Rage", "Other", "Clear on round start")
local clear_fallback_tick = ui.new_checkbox("Rage", "Other", "Clear each tick (fallback)")

ui.set(clear_decals_enable, true)
ui.set(clear_on_impact, true)
ui.set(clear_on_hurt,   true)
ui.set(clear_on_round,  true)

local function vis()
    local on = ui.get(clear_decals_enable)
    ui.set_visible(clear_on_impact, on)
    ui.set_visible(clear_on_hurt, on)
    ui.set_visible(clear_on_round, on)
    ui.set_visible(clear_fallback_tick, on)
end
ui.set_callback(clear_decals_enable, vis)
vis()

-- Engine console command alias
local function clear_decals()
    client.exec("r_cleardecals")
end

-- Events
client.set_event_callback("bullet_impact", function(e)
    if not ui.get(clear_decals_enable) or not ui.get(clear_on_impact) then return end
    clear_decals()
end)

client.set_event_callback("player_hurt", function(e)
    if not ui.get(clear_decals_enable) or not ui.get(clear_on_hurt) then return end
    clear_decals()
end)

client.set_event_callback("round_start", function()
    if not ui.get(clear_decals_enable) or not ui.get(clear_on_round) then return end
    clear_decals()
end)

-- Fallback per-tick (optional)
client.set_event_callback("run_command", function()
    if not ui.get(clear_decals_enable) or not ui.get(clear_fallback_tick) then return end
    clear_decals()
end)



-- ─────────────────────────────── Fatality.win-style Clantag: copilot.ai ───────────────────────────────
-- Syncs animation timing to server tickrate, 0–18 tick scale for speed control

local enable_ct = ui.new_checkbox("Rage", "Other", "copilot.ai fatality-style")
local tick_scale = ui.new_slider("Rage", "Other", "Tickrate scale", 0, 18, 4, true, " ticks")

local tag_text  = "copilot.ai"
local frames    = {}
local last_tag  = nil
local start_t   = globals.curtime()

-- Build animation frames: progressive reveal + hold + erase + hold
do
    for i = 1, #tag_text do
        table.insert(frames, tag_text:sub(1, i))
    end
    for _ = 1, 6 do
        table.insert(frames, tag_text)
    end
    for i = #tag_text-1, 1, -1 do
        table.insert(frames, tag_text:sub(1, i))
    end
    for _ = 1, 4 do
        table.insert(frames, "")
    end
end

local function set_tag(s)
    if s ~= last_tag then
        client.set_clan_tag(s)
        last_tag = s
    end
end

client.set_event_callback("run_command", function()
    if not ui.get(enable_ct) then return end

    local tickrate = globals.tickinterval() > 0 and (1 / globals.tickinterval()) or 64
    local scale    = ui.get(tick_scale)
    local step_len = math.max(1, tickrate / math.max(1, scale))  -- ticks per frame

    local tick     = math.floor((globals.tickcount() - (start_t / globals.tickinterval())) / step_len) % #frames
    set_tag(frames[tick + 1])
end)

ui.set_callback(enable_ct, function()
    start_t = globals.curtime()
    if not ui.get(enable_ct) then
        client.set_clan_tag("")
        last_tag = ""
    else
        last_tag = nil
    end
end)

client.set_event_callback("shutdown", function()
    client.set_clan_tag("")
end)



--[[
  HBat 0.1.0 -- バッテリー残量(%)と消費容量(mAh)の表示ウィジェット
  (EdgeTX 2.11 以降のカラー液晶機。作者の環境は EdgeTX 2.12)

  Copyright (C) 2026 Masayuki

  電流(Curr)を「時間」で積分して消費容量を求めるため、ELRSのテレメトリー比に
  依存しません。開始時の残量は、無負荷のパック電圧から VoltFuel と同じ方法
  (BattAnalogの電圧→%テーブル、セル数の自動判定、電圧安定待ち)で求めます。

    残量% = 100 - (開始オフセットmAh + 消費mAh) / Capacity * 100
    開始オフセットmAh = (100 - 開始電圧から求めた%) * Capacity / 100
    消費mAh = Σ ( Curr[A] * CurrGain[%] / 100 * 経過時間[ms] / 3600 )

  表示: 「残量%(消費mAh)」を1行で表示します。例: 75%(1250mAh)
    - 電源が接続されていない間、および開始電圧が確定するまでは 0%(0mAh)
    - 接続を外した(テレメトリーが切れた)あとは、最後の値を保持
    - 自動リセットはしません。パック交換時は送信機の電源を入れ直すか ResetSw を使います

  オプション
    CurrSrc  : 電流センサー(Curr、単位A)
    Capacity : バッテリー容量 mAh (0-7000、10mA単位に丸め)
    CurrGain : 電流の補正倍率 % (50-200、100で補正なし)
    VoltSrc  : パック電圧センサー(単位V)。必須
    Cells    : セル数。0で電圧から自動判定(開始後8秒で確定)
    ResetSw  : スイッチを上げた瞬間に積算を0に戻し、開始電圧を取り直す
    TelemOut : On で HBat(%) をテレメトリーセンサー "HBat" として出力
    Color    : 文字色
    BattType : LiPo / LiPo-HV / Li-Ion / LiFePO4(セル数判定と電圧→%に使用)

  License: GNU General Public License, version 2 (see LICENSE).
  The per-cell voltage tables, the cell-count rule and the nearest-entry
  lookup are taken from EdgeTX's BattAnalog widget (Copyright Offer Shmuely,
  GPLv2) via VoltFuel, so this widget is distributed under the same license.

  This program is free software; you can redistribute it and/or modify it
  under the terms of the GNU General Public License version 2 as published
  by the Free Software Foundation. It is distributed in the hope that it
  will be useful, but WITHOUT ANY WARRANTY; without even the implied
  warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
  GNU General Public License for more details.

  Credits: concept, requirements, flight testing and calibration: Masayuki.
  The code was written with Claude (Anthropic), an AI assistant.
--]]

local STABLE_WINDOW_VOLTS     = 0.15
local STABLE_SAMPLE_COUNT     = 5
local STABILIZE_DELAY_SECONDS = 1.5
local MAX_PLAUSIBLE_VOLTAGE   = 70    -- これを超える値はパック電圧ではない
local MAX_DT_MS               = 1000  -- 1回の積算で許す最大経過時間
local INIT_MAX_A              = 1.0   -- 開始電圧を読む時の最大電流[A](超えると負荷中)

local TELEM_ID   = 0x5C00
local TELEM_NAME = "HBat"

-- 残量バー(円を並べる)。BAR_DOTS で円の数を変えられます
local BAR_DOTS       = 20
local BAR_RED_END    = 20   -- このまで赤
local BAR_ORANGE_END = 50   -- このまで橙、それより上は緑
local ZONE_RGB = { {236, 53, 47}, {243, 191, 69}, {103, 186, 46} }  -- 赤, 橙, 緑

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- 10mA単位に丸める
local function roundCap(v)
  v = tonumber(v) or 0
  return math.floor(v / 10 + 0.5) * 10
end

local percent_list_lipo = {
    {3.000,  0},
    {3.093,  1}, {3.196,  2}, {3.301,  3}, {3.401,  4}, {3.477,  5}, {3.544,  6}, {3.601,  7}, {3.637,  8}, {3.664,  9}, {3.679, 10},
    {3.683, 11}, {3.689, 12}, {3.692, 13}, {3.705, 14}, {3.710, 15}, {3.713, 16}, {3.715, 17}, {3.720, 18}, {3.731, 19}, {3.735, 20},
    {3.744, 21}, {3.753, 22}, {3.756, 23}, {3.758, 24}, {3.762, 25}, {3.767, 26}, {3.774, 27}, {3.780, 28}, {3.783, 29}, {3.786, 30},
    {3.789, 31}, {3.794, 32}, {3.797, 33}, {3.800, 34}, {3.802, 35}, {3.805, 36}, {3.808, 37}, {3.811, 38}, {3.815, 39}, {3.818, 40},
    {3.822, 41}, {3.825, 42}, {3.829, 43}, {3.833, 44}, {3.836, 45}, {3.840, 46}, {3.843, 47}, {3.847, 48}, {3.850, 49}, {3.854, 50},
    {3.857, 51}, {3.860, 52}, {3.863, 53}, {3.866, 54}, {3.870, 55}, {3.874, 56}, {3.879, 57}, {3.888, 58}, {3.893, 59}, {3.897, 60},
    {3.902, 61}, {3.906, 62}, {3.911, 63}, {3.918, 64}, {3.923, 65}, {3.928, 66}, {3.939, 67}, {3.943, 68}, {3.949, 69}, {3.955, 70},
    {3.961, 71}, {3.968, 72}, {3.974, 73}, {3.981, 74}, {3.987, 75}, {3.994, 76}, {4.001, 77}, {4.007, 78}, {4.014, 79}, {4.021, 80},
    {4.029, 81}, {4.036, 82}, {4.044, 83}, {4.052, 84}, {4.062, 85}, {4.074, 86}, {4.085, 87}, {4.095, 88}, {4.105, 89}, {4.111, 90},
    {4.116, 91}, {4.120, 92}, {4.125, 93}, {4.129, 94}, {4.135, 95}, {4.145, 96}, {4.176, 97}, {4.179, 98}, {4.193, 99}, {4.200,100},
}

local percent_list_hv = {
    {3.000,  0},
    {3.093,  1}, {3.196,  2}, {3.301,  3}, {3.401,  4}, {3.477,  5}, {3.544,  6}, {3.601,  7}, {3.637,  8}, {3.664,  9}, {3.679, 10},
    {3.683, 11}, {3.689, 12}, {3.692, 13}, {3.705, 14}, {3.710, 15}, {3.713, 16}, {3.715, 17}, {3.720, 18}, {3.731, 19}, {3.735, 20},
    {3.744, 21}, {3.753, 22}, {3.756, 23}, {3.758, 24}, {3.762, 25}, {3.767, 26}, {3.774, 27}, {3.780, 28}, {3.783, 29}, {3.786, 30},
    {3.789, 31}, {3.794, 32}, {3.797, 33}, {3.800, 34}, {3.802, 35}, {3.805, 36}, {3.808, 37}, {3.811, 38}, {3.815, 39}, {3.828, 40},
    {3.832, 41}, {3.836, 42}, {3.841, 43}, {3.846, 44}, {3.850, 45}, {3.855, 46}, {3.859, 47}, {3.864, 48}, {3.868, 49}, {3.873, 50},
    {3.877, 51}, {3.881, 52}, {3.885, 53}, {3.890, 54}, {3.895, 55}, {3.900, 56}, {3.907, 57}, {3.917, 58}, {3.924, 59}, {3.929, 60},
    {3.936, 61}, {3.942, 62}, {3.949, 63}, {3.957, 64}, {3.964, 65}, {3.971, 66}, {3.984, 67}, {3.990, 68}, {3.998, 69}, {4.006, 70},
    {4.015, 71}, {4.024, 72}, {4.032, 73}, {4.042, 74}, {4.050, 75}, {4.060, 76}, {4.069, 77}, {4.078, 78}, {4.088, 79}, {4.098, 80},
    {4.109, 81}, {4.119, 82}, {4.130, 83}, {4.141, 84}, {4.154, 85}, {4.169, 86}, {4.184, 87}, {4.197, 88}, {4.211, 89}, {4.220, 90},
    {4.229, 91}, {4.237, 92}, {4.246, 93}, {4.254, 94}, {4.264, 95}, {4.278, 96}, {4.302, 97}, {4.320, 98}, {4.339, 99}, {4.350,100},
}

local percent_list_lion = {
    { 2.800,  0 }, { 2.840,  1 }, { 2.880,  2 }, { 2.920,  3 }, { 2.960,  4 },
    { 3.000,  5 }, { 3.040,  6 }, { 3.080,  7 }, { 3.096,  8 }, { 3.112,  9 },
    { 3.128, 10 }, { 3.144, 11 }, { 3.160, 12 }, { 3.176, 13 }, { 3.192, 14 },
    { 3.208, 15 }, { 3.224, 16 }, { 3.240, 17 }, { 3.256, 18 }, { 3.272, 19 },
    { 3.288, 20 }, { 3.304, 21 }, { 3.320, 22 }, { 3.336, 23 }, { 3.352, 24 },
    { 3.368, 25 }, { 3.384, 26 }, { 3.400, 27 }, { 3.416, 28 }, { 3.432, 29 },
    { 3.448, 30 }, { 3.464, 31 }, { 3.480, 32 }, { 3.496, 33 }, { 3.504, 34 },
    { 3.512, 35 }, { 3.520, 36 }, { 3.528, 37 }, { 3.536, 38 }, { 3.544, 39 },
    { 3.552, 40 }, { 3.560, 41 }, { 3.568, 42 }, { 3.576, 43 }, { 3.584, 44 },
    { 3.592, 45 }, { 3.600, 46 }, { 3.608, 47 }, { 3.616, 48 }, { 3.624, 49 },
    { 3.632, 50 }, { 3.640, 51 }, { 3.648, 52 }, { 3.656, 53 }, { 3.664, 54 },
    { 3.672, 55 }, { 3.680, 56 }, { 3.688, 57 }, { 3.696, 58 }, { 3.704, 59 },
    { 3.712, 60 }, { 3.720, 61 }, { 3.728, 62 }, { 3.736, 63 }, { 3.744, 64 },
    { 3.752, 65 }, { 3.760, 66 }, { 3.768, 67 }, { 3.776, 68 }, { 3.784, 69 },
    { 3.792, 70 }, { 3.800, 71 }, { 3.810, 72 }, { 3.820, 73 }, { 3.830, 74 },
    { 3.840, 75 }, { 3.850, 76 }, { 3.860, 77 }, { 3.870, 78 }, { 3.880, 79 },
    { 3.890, 80 }, { 3.900, 81 }, { 3.910, 82 }, { 3.920, 83 }, { 3.930, 84 },
    { 3.940, 85 }, { 3.950, 86 }, { 3.960, 87 }, { 3.970, 88 }, { 3.980, 89 },
    { 3.990, 90 }, { 4.000, 91 }, { 4.010, 92 }, { 4.030, 93 }, { 4.050, 94 },
    { 4.070, 95 }, { 4.090, 96 }, { 4.10, 100 }, { 4.15 ,100 }, { 4.20, 100},
}

local percent_list_life_po4 = {
    {2.500,  0},
    {2.509,  1}, {2.518,  2}, {2.527,  3}, {2.536,  4}, {2.545,  5}, {2.554,  6}, {2.563,  7}, {2.572,  8}, {2.581,  9}, {2.590, 10},
    {2.599, 11}, {2.608, 12}, {2.617, 13}, {2.626, 14}, {2.635, 15}, {2.644, 16}, {2.653, 17}, {2.662, 18}, {2.671, 19}, {2.680, 20},
    {2.689, 21}, {2.698, 22}, {2.707, 23}, {2.716, 24}, {2.725, 25}, {2.734, 26}, {2.743, 27}, {2.752, 28}, {2.761, 29}, {2.770, 30},
    {2.779, 31}, {2.788, 32}, {2.797, 33}, {2.806, 34}, {2.815, 35}, {2.824, 36}, {2.833, 37}, {2.842, 38}, {2.851, 39}, {2.860, 40},
    {2.869, 41}, {2.878, 42}, {2.887, 43}, {2.896, 44}, {2.905, 45}, {2.914, 46}, {2.923, 47}, {2.932, 48}, {2.941, 49}, {2.950, 50},
    {2.959, 51}, {2.968, 52}, {2.977, 53}, {2.986, 54}, {2.995, 55}, {3.004, 56}, {3.013, 57}, {3.022, 58}, {3.031, 59}, {3.040, 60},
    {3.049, 61}, {3.058, 62}, {3.067, 63}, {3.076, 64}, {3.085, 65}, {3.094, 66}, {3.103, 67}, {3.112, 68}, {3.121, 69}, {3.130, 70},
    {3.139, 71}, {3.148, 72}, {3.157, 73}, {3.166, 74}, {3.175, 75}, {3.184, 76}, {3.193, 77}, {3.202, 78}, {3.211, 79}, {3.220, 80},
    {3.229, 81}, {3.238, 82}, {3.247, 83}, {3.256, 84}, {3.265, 85}, {3.274, 86}, {3.283, 87}, {3.292, 88}, {3.301, 89}, {3.310, 90},
    {3.319, 91}, {3.328, 92}, {3.337, 93}, {3.346, 94}, {3.355, 95}, {3.364, 96}, {3.373, 97}, {3.382, 98}, {3.391, 99}, {3.400,100},
}

local PERCENT_LISTS = {
  percent_list_lipo, percent_list_hv, percent_list_lion, percent_list_life_po4,
}

-- Full-charge cell voltage per type; the cell-count boundary for N cells
-- is TOP_CELL_VOLTAGE * N (same rule as BattAnalog).
local TOP_CELL_VOLTAGE = { 4.30, 4.45, 4.30, 3.50 }  -- LiFePO4: reliable up to 3 cells only
local CELL_DETECTION_SECONDS = 8

local function calcCellCount(totalVoltage, battType)
  local top = TOP_CELL_VOLTAGE[battType] or TOP_CELL_VOLTAGE[1]
  for i = 1, 12 do
    if totalVoltage < top * i then return i end
  end
  return 1  -- no match (same fallback as BattAnalog)
end

-- Same result as BattAnalog's getCellPercent: 0 / 100 outside the table,
-- otherwise the nearer of the two neighbouring table entries.
local function batteryCellPercent(vCell, battType)
  local list = PERCENT_LISTS[battType] or PERCENT_LISTS[1]
  if vCell <= list[1][1] then return 0 end
  if vCell >= list[#list][1] then return 100 end
  local l, u = 1, #list
  while u - l > 1 do
    local n = math.floor((l + u) / 2)
    if vCell >= list[n][1] then l = n else u = n end
  end
  if vCell < (list[l][1] + list[u][1]) / 2 then
    return list[l][2]
  end
  return list[u][2]
end

local options = {
  { "CurrSrc",  SOURCE, 0 },
  { "Capacity", VALUE,  5000, 0, 7000 },
  { "CurrGain", VALUE,  100, 50, 200 },
  { "VoltSrc",  SOURCE, 0 },
  { "Cells",    VALUE,  0, 0, 20 },
  { "ResetSw",  SOURCE, 0 },
  { "TelemOut", CHOICE, 1, { "Off", "On" } },
  { "Color",    COLOR,  WHITE },
  { "BattType", CHOICE, 1, { "LiPo", "LiPo-HV", "Li-Ion", "LiFePO4" } },
}

-- 状態はファイル全体で共有(ウィジェットが作り直されても保持される)
local state = {
  mah             = 0,      -- 積分した消費容量 mAh(補正倍率込み)
  offset          = 0,      -- 開始電圧から求めた消費済み容量 mAh
  initDone        = false,  -- 開始電圧による初期化が済んだか
  lastTick        = nil,    -- 前回の getTime()
  resetHigh       = false,  -- ResetSw の前回状態
  cellCount       = nil,
  cellLocked      = false,
  detectStartedAt = nil,
  startedAt       = nil,
  samples         = {},
  status          = "nolink",
}

-- セル数: 手動指定ならそのまま。自動なら最初の電圧から8秒間は毎回判定し、その後固定
local function resolveCells(opt, voltage, nowS)
  if opt.Cells and opt.Cells > 0 then
    state.cellCount = opt.Cells
    state.cellLocked = true
  elseif not state.cellLocked then
    if state.detectStartedAt == nil then state.detectStartedAt = nowS end
    state.cellCount = calcCellCount(voltage, opt.BattType or 1)
    if (nowS - state.detectStartedAt) >= CELL_DETECTION_SECONDS then
      state.cellLocked = true
    end
  end
end

-- 電圧が安定したか(VoltFuelと同じ判定)
local function updateStability(voltage, nowS)
  if state.startedAt == nil then state.startedAt = nowS end
  if (nowS - state.startedAt) < STABILIZE_DELAY_SECONDS then return false end

  local samples = state.samples
  samples[#samples + 1] = voltage
  if #samples > STABLE_SAMPLE_COUNT then table.remove(samples, 1) end
  if #samples < STABLE_SAMPLE_COUNT then return false end

  local vmin, vmax = samples[1], samples[1]
  for i = 2, #samples do
    if samples[i] < vmin then vmin = samples[i] end
    if samples[i] > vmax then vmax = samples[i] end
  end
  return (vmax - vmin) <= STABLE_WINDOW_VOLTS
end

-- 開始電圧から消費済み容量(オフセット)を決める
local function startFromVoltage(opt, voltage, loaded)
  if loaded then
    state.offset = 0   -- すでに負荷中: 電圧が使えないのでオフセットなし
  else
    local vCell = voltage / math.max(state.cellCount or 1, 1)
    local startPct = batteryCellPercent(vCell, opt.BattType or 1)
    state.offset = (100 - startPct) * roundCap(opt.Capacity) / 100
  end
  state.initDone = true
end

local function step(widget)
  local opt = widget.options
  local nowTick = getTime()          -- 10ms単位
  local nowS = nowTick / 100

  -- パック電圧
  local voltage = nil
  local vsrc = opt.VoltSrc
  if vsrc == nil or vsrc == 0 then
    state.status = "nosrc"
  else
    local v = getValue(vsrc)
    if type(v) ~= "number" or v <= 1 then
      state.status = "nolink"
    elseif v > MAX_PLAUSIBLE_VOLTAGE then
      state.status = "badsrc"
    else
      voltage = v
      state.status = state.initDone and "ok" or "acq"
    end
  end

  -- 電流
  local cur = nil
  if opt.CurrSrc and opt.CurrSrc ~= 0 then
    local c = getValue(opt.CurrSrc)
    if type(c) == "number" then cur = c end
  end

  -- ResetSw(上げた瞬間だけ)
  if opt.ResetSw and opt.ResetSw ~= 0 then
    local sw = getValue(opt.ResetSw)
    local active = (sw == true) or (type(sw) == "number" and sw > 0)
    if active and not state.resetHigh then
      state.mah = 0
      state.offset = 0
      state.initDone = false
      state.samples = {}
      state.startedAt = nil
      if voltage then
        if opt.Cells and opt.Cells > 0 then
          state.cellCount = opt.Cells
        else
          state.cellCount = calcCellCount(voltage, opt.BattType or 1)
        end
        state.cellLocked = true
        startFromVoltage(opt, voltage, false)
        state.status = "ok"
      end
    end
    state.resetHigh = active
  end

  -- 経過時間(ms)。複数のウィジェットが呼んでも二重加算されないよう共有の時刻を使う
  local last = state.lastTick
  state.lastTick = nowTick
  local dt = 0
  if last ~= nil then
    dt = (nowTick - last) * 10
    if dt < 0 then dt = 0 end
    if dt > MAX_DT_MS then dt = MAX_DT_MS end
  end

  -- 開始電圧による初期化(セル数が確定し、電圧が安定してから)
  if voltage and not state.initDone then
    resolveCells(opt, voltage, nowS)
    if updateStability(voltage, nowS) and state.cellLocked then
      startFromVoltage(opt, voltage, cur ~= nil and cur > INIT_MAX_A)
      state.status = "ok"
    end
  end

  -- 電流の積分(初期化後のみ。リンクが切れている間は値を保持)
  if state.initDone and dt > 0 and cur ~= nil and cur >= 0 and getRSSI() ~= 0 then
    local gain = (tonumber(opt.CurrGain) or 100) / 100
    state.mah = state.mah + cur * gain * dt / 3600
  end
end

-- 残量%。開始電圧が確定するまでは nil
local function calcPercent(widget)
  if not state.initDone then return nil end
  local cap = roundCap(widget.options.Capacity)
  if cap <= 0 then return nil end
  local pct = 100 - (state.offset + state.mah) * 100 / cap
  return math.floor(clamp(pct, 0, 100) + 0.5)
end

-- テレメトリー出力(使えない環境でも落ちないように pcall)
local function outputTelemetry(widget, pct)
  if widget.options.TelemOut ~= 2 then return end   -- 1=Off, 2=On
  if pct == nil then return end
  if type(setTelemetryValue) == "function" then
    pcall(setTelemetryValue, TELEM_ID, 0, 0, pct, UNIT_PERCENT, 0, TELEM_NAME)
  end
end

local function create(zone, opt)
  return { zone = zone, options = opt, pct = nil }
end

local function update(widget, opt)
  widget.options = opt
  -- 設定を変えたらセル数の判定をやり直す(開始後の値には影響しない)
  state.cellCount = nil
  state.cellLocked = false
  state.detectStartedAt = nil
end

-- ウィジェットが非表示でも積算とテレメトリー出力を続ける
local function background(widget)
  step(widget)
  widget.pct = calcPercent(widget)
  outputTelemetry(widget, widget.pct)
end

-- 赤/橙/緑の色フラグ(カスタムRGBが使えない場合はテーマの色)
local customColorOk = nil
local function zoneFlag(zi)
  if customColorOk == nil then
    customColorOk = (lcd.RGB ~= nil and lcd.setColor ~= nil and CUSTOM_COLOR ~= nil)
      and pcall(lcd.setColor, CUSTOM_COLOR, lcd.RGB(0, 0, 0)) or false
  end
  if customColorOk then
    local c = ZONE_RGB[zi]
    lcd.setColor(CUSTOM_COLOR, lcd.RGB(c[1], c[2], c[3]))
    return CUSTOM_COLOR
  end
  if zi == 1 then return RED end
  if zi == 2 then return YELLOW end
  return GREEN
end

-- 円を並べた残量バー。点灯は塗りつぶし、未点灯は輪郭のみ
local function drawDotBar(x, y, w, h, pct)
  local n = BAR_DOTS
  if w < 100 then n = math.floor(n / 2) end
  local pitch = w / n
  local r = math.floor(math.min(h / 2, pitch / 2 - 1))
  if r < 2 then r = 2 end
  local cy = y + math.floor(h / 2)

  pct = clamp(pct, 0, 100)
  local lit = math.floor(pct * n / 100 + 0.5)
  if pct >= 1 and lit == 0 then lit = 1 end

  local lastZone, flag = 0, nil
  for i = 1, n do
    local frac = i * 100 / n
    local zi = 3
    if frac <= BAR_RED_END then zi = 1 elseif frac <= BAR_ORANGE_END then zi = 2 end
    if zi ~= lastZone then flag = zoneFlag(zi); lastZone = zi end
    local cx = x + math.floor(pitch * (i - 0.5) + 0.5)
    if i <= lit then
      lcd.drawFilledCircle(cx, cy, r, flag)
    else
      lcd.drawCircle(cx, cy, r, flag)
    end
  end
end

-- 幅に収まる最大のフォントを選ぶ
local function fitFont(text, maxW, zoneH)
  local order = { MIDSIZE, SMLSIZE }
  if zoneH >= 140 then
    order = { XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE }
  elseif zoneH >= 60 then
    order = { DBLSIZE, MIDSIZE, SMLSIZE }
  end
  for _, f in ipairs(order) do
    local ok, w = pcall(lcd.sizeText, text, f)
    if (not ok) or w <= maxW then return f end
  end
  return SMLSIZE
end

local function refresh(widget, event, touchState)
  background(widget)

  local zone = widget.zone
  local pct = widget.pct
  local textColor = widget.options.Color or WHITE

  -- 開始電圧が確定するまでは 0%(0mAh)
  local shownPct = pct or 0
  local shownMah = 0
  if state.initDone then shownMah = math.floor(state.mah + 0.5) end

  local barH = math.max(8, math.floor(zone.h * 0.25))
  local barY = zone.y + zone.h - barH - 4
  drawDotBar(zone.x + 4, barY, zone.w - 8, barH, shownPct)

  local label = string.format("%d%%(%dmAh)", shownPct, shownMah)
  local font = fitFont(label, zone.w - 8, zone.h)
  lcd.drawText(zone.x + 4, zone.y + 2, label, bit32.bor(font, textColor))

  -- 設定が足りない時・開始電圧を取得中のときだけ、右上に小さく状態を表示
  if pct == nil then
    local msg = nil
    if state.status == "nosrc" then msg = "Select VoltSrc"
    elseif state.status == "badsrc" then msg = "Check VoltSrc"
    elseif state.status == "acq" then msg = "Acquiring..." end
    if msg then
      lcd.drawText(zone.x + zone.w - 4, zone.y + 2, msg, bit32.bor(SMLSIZE, RIGHT, textColor))
    end
  end
end

return {
  name = "HBat",
  options = options,
  create = create,
  update = update,
  background = background,
  refresh = refresh,
}

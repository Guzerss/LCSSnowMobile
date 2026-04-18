script_name("LCSSnowMobile")
script_author("Guzers")
script_description("Credits : Rusjj, erorcun, Guzers")

local imgui = require 'mimgui'
local ffi   = require('ffi')
local hook  = require('monethook')
local mem   = require('SAMemory')
local cfg   = require('jsoncfg')

local cast = ffi.cast
local gta  = ffi.load('GTASA')
local new  = imgui.new

ffi.cdef[[
    typedef struct {
        RwV3D   pos;
        RwV3D   normal;
        RwColor color;
        float   u, v;
    } RwIm3DVertex;

    typedef struct {
        RwV3D pos;
        float xChange;
        float yChange;
    } OneSnowFlake;

    void _ZN8CWeather17RenderRainStreaksEv();
    int _Z16RwRenderStateSet13RwRenderStatePv(int state, void* value);
    void* _Z13RwTextureReadPKcS0_(const char* name, const char* mask);
    bool _Z15RwIm3DTransformP18RxObjSpace3DVertexjP11RwMatrixTagj(RwIm3DVertex* verts, uint32_t numVerts, RwMatrix* mat, uint32_t flags);
    void _Z28RwIm3DRenderIndexedPrimitive15RwPrimitiveTypePti(int primType, uint16_t* indices, int numIndices);
    void _Z9RwIm3DEndv();
    bool _ZN10CCullZones9CamNoRainEv();
    bool _ZN10CCullZones12PlayerNoRainEv();
    extern float _ZN8CWeather14UnderWaternessE;
    extern float _ZN6CTimer12ms_fTimeStepE;
]]

local rwRENDERSTATETEXTURERASTER     = 1
local rwRENDERSTATEZTESTENABLE       = 6
local rwRENDERSTATEZWRITEENABLE      = 8
local rwRENDERSTATESRCBLEND          = 10
local rwRENDERSTATEDESTBLEND         = 11
local rwRENDERSTATEVERTEXALPHAENABLE = 12
local rwRENDERSTATEFOGENABLE         = 14
local rwPRIMTYPETRILIST              = 3

local defaultConfig = {
    visible    = false,
    densityIdx = 0,
    randomness = 0.5,
}

local config = cfg.load(defaultConfig, 'LCSSnowMobile')
cfg.save(config, 'LCSSnowMobile')

local MaxSnowFlakes    = 2000
local snowFlakesArray  = ffi.new('OneSnowFlake[?]', MaxSnowFlakes)
local snowFlakesInited = false

local snowRenderOrder  = ffi.new('uint16_t[6]', {0, 1, 2, 3, 4, 5})
local white            = ffi.new('RwColor', {255, 255, 255, 255})
local snowVertexBuffer = ffi.new('RwIm3DVertex[6]')
do
    local vdata = {
        { 0.07, 0.00,  0.07, 1.0, 1.0 },
        {-0.07, 0.00,  0.07, 0.0, 1.0 },
        {-0.07, 0.00, -0.07, 0.0, 0.0 },
        { 0.07, 0.00,  0.07, 1.0, 1.0 },
        { 0.07, 0.00, -0.07, 1.0, 0.0 },
        {-0.07, 0.00, -0.07, 0.0, 0.0 },
    }
    for i, v in ipairs(vdata) do
        local sv = snowVertexBuffer[i - 1]
        sv.pos.x = v[1]; sv.pos.y = v[2]; sv.pos.z = v[3]
        sv.normal.x = 0; sv.normal.y = 0; sv.normal.z = 0
        sv.color = white
        sv.u = v[4]; sv.v = v[5]
    end
end

local snowFlakeTexture = nil
local snowFlakeRaster  = nil
local snowRasterPtr    = 0
local snowMat          = ffi.new('RwMatrix')

local densityValues = {
    [0] = math.floor(0.15 * MaxSnowFlakes),
    [1] = math.floor(0.40 * MaxSnowFlakes),
    [2] = math.floor(0.70 * MaxSnowFlakes),
    [3] = MaxSnowFlakes,
}

local currentSnowFlakes = densityValues[config.densityIdx] or densityValues[0]

local ran1    = -0.08
local ran2    =  0.08
local iflakes = 0

local SW, SH       = getScreenResolution()
local WinState     = new.bool(false)
local visible      = new.bool(config.visible)
local densityIdx   = new.int(config.densityIdx)
local randomSlider = new.float(config.randomness)

local function RS(state, value)
    gta._Z16RwRenderStateSet13RwRenderStatePv(state, cast('void*', value))
end

local function clamp(v, mn, mx)
    if v > mx then return mx end
    if v < mn then return mn end
    return v
end

local function saveConfig()
    config.visible    = visible[0]
    config.densityIdx = densityIdx[0]
    config.randomness = randomSlider[0]
    cfg.save(config, 'LCSSnowMobile')
end

local function addSnow()
    local ok1, camNoRain    = pcall(gta._ZN10CCullZones9CamNoRainEv)
    local ok2, playerNoRain = pcall(gta._ZN10CCullZones12PlayerNoRainEv)
    if (ok1 and camNoRain) or (ok2 and playerNoRain) then return end
    if gta._ZN8CWeather14UnderWaternessE > 0 then return end
    if snowRasterPtr == 0 then return end

    local snowAmount = math.min(currentSnowFlakes, MaxSnowFlakes)
    if snowAmount <= 0 then return end

    local cm      = cast('RwMatrix*', mem.camera.pMatrix)
    local camPos  = cm.pos
    local camPosX = camPos.x
    local camPosY = camPos.y
    local camPosZ = camPos.z
    local bxMinX  = camPosX - 40.0; local bxMaxX = camPosX + 40.0
    local bxMinY  = camPosY - 40.0; local bxMaxY = camPosY + 40.0
    local bxMinZ  = camPosZ - 15.0; local bxMaxZ = camPosZ + 15.0

    if not snowFlakesInited then
        snowFlakesInited = true
        for i = 0, MaxSnowFlakes - 1 do
            snowFlakesArray[i].pos.x   = bxMinX + (bxMaxX - bxMinX) * math.random()
            snowFlakesArray[i].pos.y   = bxMinY + (bxMaxY - bxMinY) * math.random()
            snowFlakesArray[i].pos.z   = bxMinZ + (bxMaxZ - bxMinZ) * math.random()
            snowFlakesArray[i].xChange = 0
            snowFlakesArray[i].yChange = 0
        end
    end

    RS(rwRENDERSTATEFOGENABLE,         0)
    RS(rwRENDERSTATETEXTURERASTER,     snowRasterPtr)
    RS(rwRENDERSTATEZTESTENABLE,       1)
    RS(rwRENDERSTATEZWRITEENABLE,      0)
    RS(rwRENDERSTATEVERTEXALPHAENABLE, 1)
    RS(rwRENDERSTATESRCBLEND,          2)
    RS(rwRENDERSTATEDESTBLEND,         2)

    snowMat.right.x = cm.right.x; snowMat.right.y = cm.right.y; snowMat.right.z = cm.right.z
    snowMat.up.x    = cm.up.x;    snowMat.up.y    = cm.up.y;    snowMat.up.z    = cm.up.z
    snowMat.at.x    = cm.at.x;    snowMat.at.y    = cm.at.y;    snowMat.at.z    = cm.at.z

    local maxChange  = 0.03 * gta._ZN6CTimer12ms_fTimeStepE
    local minChange  = -maxChange
    local rnd        = randomSlider[0]
    local updateEvery = math.max(1, math.floor(64 * (1.0 - rnd)))

    for i = 0, snowAmount - 1 do
        iflakes = iflakes + 1
        if iflakes % updateEvery == 0 then
            ran1    = minChange + (2 * maxChange * math.random())
            ran2    = minChange + (2 * maxChange * math.random())
            iflakes = 0
        end

        local flake = snowFlakesArray[i]
        local fx = flake.pos.x
        local fy = flake.pos.y
        local fz = flake.pos.z - maxChange
        local xc = clamp(flake.xChange + ran1, minChange, maxChange)
        local yc = clamp(flake.yChange + ran2, minChange, maxChange)
        fx = fx + xc
        fy = fy + yc

        while fz < bxMinZ do fz = fz + 30.0 end
        while fz > bxMaxZ do fz = fz - 30.0 end
        while fx < bxMinX do fx = fx + 80.0 end
        while fx > bxMaxX do fx = fx - 80.0 end
        while fy < bxMinY do fy = fy + 80.0 end
        while fy > bxMaxY do fy = fy - 80.0 end

        flake.pos.x   = fx
        flake.pos.y   = fy
        flake.pos.z   = fz
        flake.xChange = xc
        flake.yChange = yc

        snowMat.pos.x = fx
        snowMat.pos.y = fy
        snowMat.pos.z = fz

        if gta._Z15RwIm3DTransformP18RxObjSpace3DVertexjP11RwMatrixTagj(snowVertexBuffer, 6, snowMat, 1) then
            gta._Z28RwIm3DRenderIndexedPrimitive15RwPrimitiveTypePti(rwPRIMTYPETRILIST, snowRenderOrder, 6)
            gta._Z9RwIm3DEndv()
        end
    end

    RS(rwRENDERSTATEZTESTENABLE,       1)
    RS(rwRENDERSTATEZWRITEENABLE,      1)
    RS(rwRENDERSTATESRCBLEND,          5)
    RS(rwRENDERSTATEDESTBLEND,         6)
    RS(rwRENDERSTATEFOGENABLE,         0)
    RS(rwRENDERSTATEVERTEXALPHAENABLE, 0)
end

local rainStreaksHook
rainStreaksHook = hook.new(
    'void(*)()',
    function()
        rainStreaksHook()
        if visible[0] then pcall(addSnow) end
    end,
    cast('uintptr_t', cast('void*', gta._ZN8CWeather17RenderRainStreaksEv))
)

imgui.OnFrame(
    function() return WinState[0] end,
    function()
        imgui.SetNextWindowPos(imgui.ImVec2(SW / 2, SH / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin('LCSSnowMobile', WinState, imgui.WindowFlags.NoCollapse)
        imgui.PushItemWidth(imgui.GetContentRegionAvail().x)
        if imgui.Checkbox('Enable', visible) then saveConfig() end
        local densityLabels = {'Low', 'Medium', 'High', 'Very High'}
        if imgui.SliderInt('##density', densityIdx, 0, 3, densityLabels[densityIdx[0] + 1]) then
            currentSnowFlakes = densityValues[densityIdx[0]]
            saveConfig()
        end
        if imgui.SliderFloat('##randomness', randomSlider, 0.0, 1.0, 'Randomness: %.2f') then saveConfig() end
        imgui.PopItemWidth()
        imgui.End()
    end
)

function main()
    local tex = gta._Z13RwTextureReadPKcS0_('shad_exp', nil)
    if tex ~= nil then
        snowFlakeTexture = cast('RwTexture*', tex)
        snowFlakeRaster  = snowFlakeTexture.raster
        snowRasterPtr    = tonumber(cast('uintptr_t', snowFlakeRaster))
    end
    sampRegisterChatCommand('snow', function() WinState[0] = not WinState[0] end)
    wait(-1)
end

addEventHandler('onScriptTerminate', function(scr)
    if scr == script.this then rainStreaksHook.stop() end
end)

const std = @import("std");
const log = @import("std").log;
const fs = @import("std").fs;
const mem = @import("std").mem;
const math = @import("std").math;
const fmt = @import("std").fmt;

const File = std.fs.File;
const Log = std.log.Log;
const SharedFD = std.os.fd_t;
const ControlList = std.os.ControlList;
const ControlInfoMap = std.os.ControlInfoMap;
const ControlInfo = std.os.ControlInfo;
const CameraSensorHelper = std.os.CameraSensorHelper;
const CameraSensorHelperFactoryBase = std.os.CameraSensorHelperFactoryBase;
const DebayerParams = std.os.DebayerParams;
const SwIspStats = std.os.SwIspStats;
const YamlObject = std.os.YamlObject;
const YamlParser = std.os.YamlParser;
const IPASettings = std.os.IPASettings;
const IPAConfigInfo = std.os.IPAConfigInfo;
const IPAModuleInfo = std.os.IPAModuleInfo;
const IPAInterface = std.os.IPAInterface;
const IPASoftInterface = std.os.IPASoftInterface;
const Module = std.os.Module;
const IPAContext = std.os.IPAContext;
const IPAFrameContext = std.os.IPAFrameContext;

const kMaxFrameContexts = 16;

const IPASoftSimple = struct {
    context: IPAContext,
    params: ?*DebayerParams,
    stats: ?*SwIspStats,
    camHelper: ?*CameraSensorHelper,
    sensorInfoMap: ControlInfoMap,

    pub fn init(self: *IPASoftSimple, settings: IPASettings, fdStats: SharedFD, fdParams: SharedFD, sensorInfoMap: ControlInfoMap, ipaControls: *ControlInfoMap) !void {
        self.camHelper = CameraSensorHelperFactoryBase.create(settings.sensorModel);
        if (self.camHelper == null) {
            log.warn("Failed to create camera sensor helper for {}", .{settings.sensorModel});
        }

        var file = try File.openRead(settings.configurationFile);
        defer file.close();

        var data = try YamlParser.parse(file);
        if (data == null) {
            return error.InvalidArgument;
        }

        var version = data.get("version").getOptional(u32, 0);
        log.debug("Tuning file version {}", .{version});

        if (!data.contains("algorithms")) {
            log.error("Tuning file doesn't contain algorithms");
            return error.InvalidArgument;
        }

        try self.createAlgorithms(self.context, data.get("algorithms"));

        self.params = null;
        self.stats = null;

        if (!fdStats.isValid()) {
            log.error("Invalid Statistics handle");
            return error.NoDevice;
        }

        if (!fdParams.isValid()) {
            log.error("Invalid Parameters handle");
            return error.NoDevice;
        }

        {
            var mem = try std.os.mmap(null, @sizeOf(DebayerParams), std.os.PROT_WRITE, std.os.MAP_SHARED, fdParams, 0);
            self.params = @ptrCast(*DebayerParams, mem);
        }

        {
            var mem = try std.os.mmap(null, @sizeOf(SwIspStats), std.os.PROT_READ, std.os.MAP_SHARED, fdStats, 0);
            self.stats = @ptrCast(*SwIspStats, mem);
        }

        var ctrlMap = self.context.ctrlMap;
        *ipaControls = ControlInfoMap.init(std.move(ctrlMap), controls.controls);

        if (!sensorInfoMap.contains(V4L2_CID_EXPOSURE)) {
            log.error("Don't have exposure control");
            return error.InvalidArgument;
        }

        if (!sensorInfoMap.contains(V4L2_CID_ANALOGUE_GAIN)) {
            log.error("Don't have gain control");
            return error.InvalidArgument;
        }
    }

    pub fn configure(self: *IPASoftSimple, configInfo: IPAConfigInfo) !void {
        self.sensorInfoMap = configInfo.sensorControls;

        var exposureInfo = self.sensorInfoMap.get(V4L2_CID_EXPOSURE);
        var gainInfo = self.sensorInfoMap.get(V4L2_CID_ANALOGUE_GAIN);

        self.context.configuration = undefined;
        self.context.activeState = undefined;
        self.context.frameContexts.clear();

        self.context.configuration.agc.exposureMin = exposureInfo.min().get(i32);
        self.context.configuration.agc.exposureMax = exposureInfo.max().get(i32);
        if (self.context.configuration.agc.exposureMin == 0) {
            log.warn("Minimum exposure is zero, that can't be linear");
            self.context.configuration.agc.exposureMin = 1;
        }

        var againMin = gainInfo.min().get(i32);
        var againMax = gainInfo.max().get(i32);

        if (self.camHelper != null) {
            self.context.configuration.agc.againMin = self.camHelper.gain(againMin);
            self.context.configuration.agc.againMax = self.camHelper.gain(againMax);
            self.context.configuration.agc.againMinStep = (self.context.configuration.agc.againMax - self.context.configuration.agc.againMin) / 100.0;
            if (self.camHelper.blackLevel().has_value()) {
                self.context.configuration.black.level = self.camHelper.blackLevel().value() / 256;
            }
        } else {
            self.context.configuration.agc.againMax = againMax;
            if (againMin == 0) {
                log.warn("Minimum gain is zero, that can't be linear");
                self.context.configuration.agc.againMin = math.min(100, againMin / 2 + againMax / 2);
            }
            self.context.configuration.agc.againMinStep = 1.0;
        }

        for (algo in self.algorithms()) |algo| {
            try algo.configure(self.context, configInfo);
        }

        log.info("Exposure {}-{}, gain {}-{} ({})", .{self.context.configuration.agc.exposureMin, self.context.configuration.agc.exposureMax, self.context.configuration.agc.againMin, self.context.configuration.agc.againMax, self.context.configuration.agc.againMinStep});
    }

    pub fn start(self: *IPASoftSimple) !void {
        // No implementation needed
    }

    pub fn stop(self: *IPASoftSimple) !void {
        self.context.frameContexts.clear();
    }

    pub fn queueRequest(self: *IPASoftSimple, frame: u32, controls: ControlList) !void {
        var frameContext = self.context.frameContexts.alloc(frame);

        for (algo in self.algorithms()) |algo| {
            try algo.queueRequest(self.context, frame, frameContext, controls);
        }
    }

    pub fn computeParams(self: *IPASoftSimple, frame: u32) !void {
        var frameContext = self.context.frameContexts.get(frame);
        for (algo in self.algorithms()) |algo| {
            try algo.prepare(self.context, frame, frameContext, self.params);
        }
        self.setIspParams();
    }

    pub fn processStats(self: *IPASoftSimple, frame: u32, bufferId: u32, sensorControls: ControlList) !void {
        var frameContext = self.context.frameContexts.get(frame);

        frameContext.sensor.exposure = sensorControls.get(V4L2_CID_EXPOSURE).get(i32);
        var again = sensorControls.get(V4L2_CID_ANALOGUE_GAIN).get(i32);
        frameContext.sensor.gain = if (self.camHelper != null) self.camHelper.gain(again) else again;

        var metadata = ControlList.init(controls.controls);
        for (algo in self.algorithms()) |algo| {
            try algo.process(self.context, frame, frameContext, self.stats, metadata);
        }

        if (!sensorControls.contains(V4L2_CID_EXPOSURE) || !sensorControls.contains(V4L2_CID_ANALOGUE_GAIN)) {
            log.error("Control(s) missing");
            return;
        }

        var ctrls = ControlList.init(self.sensorInfoMap);

        var againNew = frameContext.sensor.gain;
        ctrls.set(V4L2_CID_EXPOSURE, frameContext.sensor.exposure);
        ctrls.set(V4L2_CID_ANALOGUE_GAIN, if (self.camHelper != null) self.camHelper.gainCode(againNew) else againNew);

        self.setSensorControls(ctrls);
    }

    pub fn logPrefix(self: *IPASoftSimple) ![]const u8 {
        return "IPASoft";
    }
};

extern "c" fn ipaCreate() *IPAInterface {
    return try IPASoftSimple.init();
}

extern "c" const ipaModuleInfo: IPAModuleInfo = IPAModuleInfo{
    api_version: IPA_MODULE_API_VERSION,
    flags: 0,
    name: "simple",
    description: "simple",
};

const std = @import("std");
const log = @import("std").log;
const fmt = @import("std").fmt;
const mem = @import("std").mem;
const bayer = @import("bayer_format");
const mapped_framebuffer = @import("mapped_framebuffer");
const yaml = @import("yaml_parser");
const algorithms = @import("algorithms");
const camera_sensor_helper = @import("camera_sensor_helper");
const ipa_context = @import("ipa_context");

const kMaxFrameContexts = 16;

pub const IPAMaliC55 = struct {
    context: ipa_context.IPAContext,

    pub fn init(self: *IPAMaliC55, settings: IPASettings, ipaConfig: IPAConfigInfo, ipaControls: *ControlInfoMap) !void {
        self.context = ipa_context.IPAContext.init(kMaxFrameContexts);

        self.camHelper = try camera_sensor_helper.CameraSensorHelperFactoryBase.create(settings.sensorModel);
        if (self.camHelper == null) {
            return error.FailedToCreateCameraSensorHelper;
        }

        var file = try std.fs.File.openRead(settings.configurationFile);
        defer file.close();

        var data = try yaml.YamlParser.parse(file);
        if (!data.contains("algorithms")) {
            return error.TuningFileMissingAlgorithms;
        }

        try algorithms.createAlgorithms(self.context, data["algorithms"]);
        self.updateControls(ipaConfig.sensorInfo, ipaConfig.sensorControls, ipaControls);
    }

    pub fn start(self: *IPAMaliC55) !void {
        // No-op
    }

    pub fn stop(self: *IPAMaliC55) void {
        self.context.frameContexts.clear();
    }

    pub fn configure(self: *IPAMaliC55, ipaConfig: IPAConfigInfo, bayerOrder: u8, ipaControls: *ControlInfoMap) !void {
        self.sensorControls = ipaConfig.sensorControls;

        self.context.configuration = undefined;
        self.context.activeState = undefined;
        self.context.frameContexts.clear();

        const info = ipaConfig.sensorInfo;
        self.updateSessionConfiguration(info, ipaConfig.sensorControls, @intToEnum(bayer.BayerFormat.Order, bayerOrder));
        self.updateControls(info, ipaConfig.sensorControls, ipaControls);

        for (algo in self.algorithms) |a| {
            try a.configure(self.context, info);
        }
    }

    pub fn mapBuffers(self: *IPAMaliC55, buffers: []const IPABuffer, readOnly: bool) void {
        for (buffer in buffers) |b| {
            const fb = FrameBuffer.init(b.planes);
            self.buffers.insert(b.id, mapped_framebuffer.MappedFrameBuffer.init(&fb, if (readOnly) mapped_framebuffer.MappedFrameBuffer.MapFlag.Read else mapped_framebuffer.MappedFrameBuffer.MapFlag.ReadWrite));
        }
    }

    pub fn unmapBuffers(self: *IPAMaliC55, buffers: []const IPABuffer) void {
        for (buffer in buffers) |b| {
            self.buffers.remove(b.id);
        }
    }

    pub fn queueRequest(self: *IPAMaliC55, request: u32, controls: ControlList) void {
        var frameContext = self.context.frameContexts.alloc(request);

        for (algo in self.algorithms) |a| {
            a.queueRequest(self.context, request, frameContext, controls);
        }
    }

    pub fn fillParams(self: *IPAMaliC55, request: u32, bufferId: u32) void {
        var params = self.buffers[bufferId].planes[0].data;
        std.mem.set(params, 0, std.mem.sizeOf(params));

        params.version = MALI_C55_PARAM_BUFFER_V1;

        for (algo in self.algorithms) |a| {
            a.prepare(self.context, request, self.context.frameContexts.get(request), params);
            assert(params.total_size <= MALI_C55_PARAMS_MAX_SIZE);
        }

        self.paramsComputed.emit(request);
    }

    pub fn processStats(self: *IPAMaliC55, request: u32, bufferId: u32, sensorControls: ControlList) void {
        var frameContext = self.context.frameContexts.get(request);
        const stats = self.buffers[bufferId].planes[0].data;

        frameContext.agc.exposure = sensorControls.get(V4L2_CID_EXPOSURE).getInt();
        frameContext.agc.sensorGain = self.camHelper.gain(sensorControls.get(V4L2_CID_ANALOGUE_GAIN).getInt());

        var metadata = ControlList.init(controls.controls);

        for (algo in self.algorithms) |a| {
            a.process(self.context, request, frameContext, stats, metadata);
        }

        self.setControls();
        self.statsProcessed.emit(request, metadata);
    }

    fn updateSessionConfiguration(self: *IPAMaliC55, info: IPACameraSensorInfo, sensorControls: ControlInfoMap, bayerOrder: bayer.BayerFormat.Order) void {
        self.context.configuration.sensor.bayerOrder = bayerOrder;

        const v4l2Exposure = sensorControls.find(V4L2_CID_EXPOSURE).second;
        const minExposure = v4l2Exposure.min().getInt();
        const maxExposure = v4l2Exposure.max().getInt();
        const defExposure = v4l2Exposure.def().getInt();

        const v4l2Gain = sensorControls.find(V4L2_CID_ANALOGUE_GAIN).second;
        const minGain = v4l2Gain.min().getInt();
        const maxGain = v4l2Gain.max().getInt();

        self.context.configuration.sensor.lineDuration = info.minLineLength * 1.0s / info.pixelRate;
        self.context.configuration.agc.minShutterSpeed = minExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.agc.maxShutterSpeed = maxExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.agc.defaultExposure = defExposure;
        self.context.configuration.agc.minAnalogueGain = self.camHelper.gain(minGain);
        self.context.configuration.agc.maxAnalogueGain = self.camHelper.gain(maxGain);

        if (self.camHelper.blackLevel().has_value()) {
            self.context.configuration.sensor.blackLevel = self.camHelper.blackLevel().value() << 4;
        }
    }

    fn updateControls(self: *IPAMaliC55, sensorInfo: IPACameraSensorInfo, sensorControls: ControlInfoMap, ipaControls: *ControlInfoMap) void {
        var ctrlMap = ControlInfoMap.Map.init();

        const v4l2HBlank = sensorControls.find(V4L2_CID_HBLANK).second;
        const hblank = v4l2HBlank.def().getInt();
        const lineLength = sensorInfo.outputSize.width + hblank;

        const v4l2VBlank = sensorControls.find(V4L2_CID_VBLANK).second;
        const frameHeights = [_]u32{
            v4l2VBlank.min().getInt() + sensorInfo.outputSize.height,
            v4l2VBlank.max().getInt() + sensorInfo.outputSize.height,
            v4l2VBlank.def().getInt() + sensorInfo.outputSize.height,
        };

        const frameDurations = [_]i64{
            frameHeights[0] * lineLength / (sensorInfo.pixelRate / 1000000),
            frameHeights[1] * lineLength / (sensorInfo.pixelRate / 1000000),
            frameHeights[2] * lineLength / (sensorInfo.pixelRate / 1000000),
        };

        ctrlMap.insert(&controls.FrameDurationLimits, ControlInfo.init(frameDurations[0], frameDurations[1], frameDurations[2]));

        const lineDuration = sensorInfo.minLineLength / sensorInfo.pixelRate;

        const v4l2Exposure = sensorControls.find(V4L2_CID_EXPOSURE).second;
        const minExposure = v4l2Exposure.min().getInt() * lineDuration;
        const maxExposure = v4l2Exposure.max().getInt() * lineDuration;
        const defExposure = v4l2Exposure.def().getInt() * lineDuration;
        ctrlMap.insert(&controls.ExposureTime, ControlInfo.init(minExposure, maxExposure, defExposure));

        const v4l2Gain = sensorControls.find(V4L2_CID_ANALOGUE_GAIN).second;
        const minGain = self.camHelper.gain(v4l2Gain.min().getInt());
        const maxGain = self.camHelper.gain(v4l2Gain.max().getInt());
        const defGain = self.camHelper.gain(v4l2Gain.def().getInt());
        ctrlMap.insert(&controls.AnalogueGain, ControlInfo.init(minGain, maxGain, defGain));

        ctrlMap.merge(self.context.ctrlMap);

        *ipaControls = ControlInfoMap.init(ctrlMap, controls.controls);
    }

    fn setControls(self: *IPAMaliC55) void {
        const activeState = self.context.activeState;
        var exposure: u32;
        var gain: u32;

        if (activeState.agc.autoEnabled) {
            exposure = activeState.agc.automatic.exposure;
            gain = self.camHelper.gainCode(activeState.agc.automatic.sensorGain);
        } else {
            exposure = activeState.agc.manual.exposure;
            gain = self.camHelper.gainCode(activeState.agc.manual.sensorGain);
        }

        var ctrls = ControlList.init(self.sensorControls);
        ctrls.set(V4L2_CID_EXPOSURE, exposure);
        ctrls.set(V4L2_CID_ANALOGUE_GAIN, gain);

        self.setSensorControls.emit(ctrls);
    }
};

extern "C" fn ipaCreate() *IPAMaliC55 {
    return try std.heap.page_allocator.create(IPAMaliC55);
}

extern "C" const ipaModuleInfo = IPAModuleInfo{
    .api_version = IPA_MODULE_API_VERSION,
    .version = 1,
    .name = "mali-c55",
    .description = "mali-c55",
};

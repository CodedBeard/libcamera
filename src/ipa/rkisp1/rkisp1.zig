const std = @import("std");
const log = @import("log");
const controls = @import("controls");
const core_ipa_interface = @import("core_ipa_interface");
const yaml_parser = @import("yaml_parser");
const formats = @import("formats");
const mapped_framebuffer = @import("mapped_framebuffer");
const algorithms = @import("algorithms/algorithm");

const IPARkISP1 = struct {
    context: IPAContext,
    buffers: std.AutoHashMap(u32, FrameBuffer),
    mappedBuffers: std.AutoHashMap(u32, MappedFrameBuffer),
    sensorControls: ControlInfoMap,

    pub fn init(self: *IPARkISP1, settings: IPASettings, hwRevision: u32, sensorInfo: IPACameraSensorInfo, sensorControls: ControlInfoMap, ipaControls: *ControlInfoMap) i32 {
        switch (hwRevision) {
            RKISP1_V10 => self.context.hw = &ipaHwSettingsV10,
            RKISP1_V_IMX8MP => self.context.hw = &ipaHwSettingsIMX8MP,
            RKISP1_V12 => self.context.hw = &ipaHwSettingsV12,
            else => {
                log.error("IPARkISP1", "Hardware revision {d} is currently not supported", .{ hwRevision });
                return -ENODEV;
            }
        }

        log.debug("IPARkISP1", "Hardware revision is {d}", .{ hwRevision });

        self.context.sensorInfo = sensorInfo;

        self.context.camHelper = CameraSensorHelperFactoryBase.create(settings.sensorModel);
        if (self.context.camHelper == null) {
            log.error("IPARkISP1", "Failed to create camera sensor helper for {s}", .{ settings.sensorModel });
            return -ENODEV;
        }

        self.context.configuration.sensor.lineDuration = sensorInfo.minLineLength * 1.0s / sensorInfo.pixelRate;

        const file = try File.open(settings.configurationFile, .{ .read = true });
        defer file.close();

        const data = try YamlParser.parse(file);
        if (data == null) return -EINVAL;

        const version = data.get("version").getOptional(u32) orelse 0;
        if (version != 1) {
            log.error("IPARkISP1", "Invalid tuning file version {d}", .{ version });
            return -EINVAL;
        }

        if (!data.contains("algorithms")) {
            log.error("IPARkISP1", "Tuning file doesn't contain any algorithm");
            return -EINVAL;
        }

        const ret = self.createAlgorithms(self.context, data.get("algorithms"));
        if (ret != 0) return ret;

        self.updateControls(sensorInfo, sensorControls, ipaControls);

        return 0;
    }

    pub fn start(self: *IPARkISP1) i32 {
        self.setControls(0);
        return 0;
    }

    pub fn stop(self: *IPARkISP1) void {
        self.context.frameContexts.clear();
    }

    pub fn configure(self: *IPARkISP1, ipaConfig: IPAConfigInfo, streamConfig: std.AutoHashMap(u32, IPAStream), ipaControls: *ControlInfoMap) i32 {
        self.sensorControls = ipaConfig.sensorControls;

        const itExp = self.sensorControls.get(V4L2_CID_EXPOSURE);
        const minExposure = itExp.min().get(i32);
        const maxExposure = itExp.max().get(i32);

        const itGain = self.sensorControls.get(V4L2_CID_ANALOGUE_GAIN);
        const minGain = itGain.min().get(i32);
        const maxGain = itGain.max().get(i32);

        log.debug("IPARkISP1", "Exposure: [{d}, {d}], gain: [{d}, {d}]", .{ minExposure, maxExposure, minGain, maxGain });

        self.context.configuration = undefined;
        self.context.activeState = undefined;
        self.context.frameContexts.clear();

        self.context.configuration.paramFormat = ipaConfig.paramFormat;

        const info = ipaConfig.sensorInfo;
        const vBlank = self.sensorControls.get(V4L2_CID_VBLANK);
        self.context.configuration.sensor.defVBlank = vBlank.def().get(i32);
        self.context.configuration.sensor.size = info.outputSize;
        self.context.configuration.sensor.lineDuration = info.minLineLength * 1.0s / info.pixelRate;

        self.updateControls(info, self.sensorControls, ipaControls);

        self.context.configuration.sensor.minExposureTime = minExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.sensor.maxExposureTime = maxExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.sensor.minAnalogueGain = self.context.camHelper.gain(minGain);
        self.context.configuration.sensor.maxAnalogueGain = self.context.camHelper.gain(maxGain);

        self.context.configuration.raw = std.algorithm.any(streamConfig, (IPAStream stream) {
            const pixelFormat = PixelFormat{ .value = stream.pixelFormat };
            const format = PixelFormatInfo.info(pixelFormat);
            return format.colourEncoding == PixelFormatInfo.ColourEncodingRAW;
        });

        for (self.algorithms()) |algo| {
            if (algo.disabled) continue;
            const ret = algo.configure(self.context, info);
            if (ret != 0) return ret;
        }

        return 0;
    }

    pub fn mapBuffers(self: *IPARkISP1, buffers: []const IPABuffer) void {
        for (buffers) |buffer| {
            const fb = FrameBuffer{ .planes = buffer.planes };
            self.buffers.put(buffer.id, fb);

            const mappedBuffer = try MappedFrameBuffer.init(&fb, .{ .read = true, .write = true });
            if (!mappedBuffer.isValid()) {
                log.fatal("IPARkISP1", "Failed to mmap buffer: {s}", .{ mappedBuffer.error() });
            }

            self.mappedBuffers.put(buffer.id, mappedBuffer);
        }
    }

    pub fn unmapBuffers(self: *IPARkISP1, ids: []const u32) void {
        for (ids) |id| {
            if (self.buffers.get(id) != null) {
                self.mappedBuffers.remove(id);
                self.buffers.remove(id);
            }
        }
    }

    pub fn queueRequest(self: *IPARkISP1, frame: u32, controls: ControlList) void {
        const frameContext = self.context.frameContexts.alloc(frame);
        self.context.debugMetadata.enableByControl(controls);

        for (self.algorithms()) |algo| {
            if (algo.disabled) continue;
            algo.queueRequest(self.context, frame, frameContext, controls);
        }
    }

    pub fn computeParams(self: *IPARkISP1, frame: u32, bufferId: u32) void {
        const frameContext = self.context.frameContexts.get(frame);

        const params = RkISP1Params{ .format = self.context.configuration.paramFormat, .data = self.mappedBuffers.get(bufferId).planes[0] };

        for (self.algorithms()) |algo| {
            algo.prepare(self.context, frame, frameContext, &params);
        }

        self.paramsComputed.emit(frame, params.size());
    }

    pub fn processStats(self: *IPARkISP1, frame: u32, bufferId: u32, sensorControls: ControlList) void {
        const frameContext = self.context.frameContexts.get(frame);

        const stats = if (!self.context.configuration.raw) {
            self.mappedBuffers.get(bufferId).planes[0].data
        } else null;

        frameContext.sensor.exposure = sensorControls.get(V4L2_CID_EXPOSURE).get(i32);
        frameContext.sensor.gain = self.context.camHelper.gain(sensorControls.get(V4L2_CID_ANALOGUE_GAIN).get(i32));

        const metadata = ControlList{ .controls = controls.controls };

        for (self.algorithms()) |algo| {
            if (algo.disabled) continue;
            algo.process(self.context, frame, frameContext, stats, &metadata);
        }

        self.setControls(frame);

        self.context.debugMetadata.moveEntries(&metadata);
        self.metadataReady.emit(frame, &metadata);
    }

    fn updateControls(self: *IPARkISP1, sensorInfo: IPACameraSensorInfo, sensorControls: ControlInfoMap, ipaControls: *ControlInfoMap) void {
        var ctrlMap = ControlInfoMap{ .map = rkisp1Controls };

        const lineDuration = self.context.configuration.sensor.lineDuration.getMicroseconds();
        const v4l2Exposure = sensorControls.get(V4L2_CID_EXPOSURE);
        const minExposure = v4l2Exposure.min().get(i32) * lineDuration;
        const maxExposure = v4l2Exposure.max().get(i32) * lineDuration;
        const defExposure = v4l2Exposure.def().get(i32) * lineDuration;
        ctrlMap.put(&controls.ExposureTime, ControlInfo{ .min = minExposure, .max = maxExposure, .def = defExposure });

        const v4l2Gain = sensorControls.get(V4L2_CID_ANALOGUE_GAIN);
        const minGain = self.context.camHelper.gain(v4l2Gain.min().get(i32));
        const maxGain = self.context.camHelper.gain(v4l2Gain.max().get(i32));
        const defGain = self.context.camHelper.gain(v4l2Gain.def().get(i32));
        ctrlMap.put(&controls.AnalogueGain, ControlInfo{ .min = minGain, .max = maxGain, .def = defGain });

        const v4l2HBlank = sensorControls.get(V4L2_CID_HBLANK);
        const hblank = v4l2HBlank.def().get(i32);
        const lineLength = sensorInfo.outputSize.width + hblank;

        const v4l2VBlank = sensorControls.get(V4L2_CID_VBLANK);
        const frameHeights = [3]u32{
            v4l2VBlank.min().get(i32) + sensorInfo.outputSize.height,
            v4l2VBlank.max().get(i32) + sensorInfo.outputSize.height,
            v4l2VBlank.def().get(i32) + sensorInfo.outputSize.height,
        };

        const frameDurations = [3]i64{};
        for (frameHeights) |height, i| {
            const frameSize = lineLength * height;
            frameDurations[i] = frameSize / (sensorInfo.pixelRate / 1000000);
        }

        ctrlMap.put(&controls.FrameDurationLimits, ControlInfo{ .min = frameDurations[0], .max = frameDurations[1], .def = frameDurations[2] });

        ctrlMap.merge(self.context.ctrlMap);
        *ipaControls = ControlInfoMap{ .map = ctrlMap, .controls = controls.controls };
    }

    fn setControls(self: *IPARkISP1, frame: u32) void {
        const frameContext = self.context.frameContexts.get(frame);
        const exposure = frameContext.agc.exposure;
        const gain = self.context.camHelper.gainCode(frameContext.agc.gain);

        const ctrls = ControlList{ .controls = self.sensorControls };
        ctrls.set(V4L2_CID_EXPOSURE, exposure);
        ctrls.set(V4L2_CID_ANALOGUE_GAIN, gain);

        self.setSensorControls.emit(frame, &ctrls);
    }
};

const ipaHwSettingsV10 = IPAHwSettings{
    .numAeCells = RKISP1_CIF_ISP_AE_MEAN_MAX_V10,
    .numHistogramBins = RKISP1_CIF_ISP_HIST_BIN_N_MAX_V10,
    .numHistogramWeights = RKISP1_CIF_ISP_HISTOGRAM_WEIGHT_GRIDS_SIZE_V10,
    .numGammaOutSamples = RKISP1_CIF_ISP_GAMMA_OUT_MAX_SAMPLES_V10,
    .compand = false,
};

const ipaHwSettingsIMX8MP = IPAHwSettings{
    .numAeCells = RKISP1_CIF_ISP_AE_MEAN_MAX_V10,
    .numHistogramBins = RKISP1_CIF_ISP_HIST_BIN_N_MAX_V10,
    .numHistogramWeights = RKISP1_CIF_ISP_HISTOGRAM_WEIGHT_GRIDS_SIZE_V10,
    .numGammaOutSamples = RKISP1_CIF_ISP_GAMMA_OUT_MAX_SAMPLES_V10,
    .compand = true,
};

const ipaHwSettingsV12 = IPAHwSettings{
    .numAeCells = RKISP1_CIF_ISP_AE_MEAN_MAX_V12,
    .numHistogramBins = RKISP1_CIF_ISP_HIST_BIN_N_MAX_V12,
    .numHistogramWeights = RKISP1_CIF_ISP_HISTOGRAM_WEIGHT_GRIDS_SIZE_V12,
    .numGammaOutSamples = RKISP1_CIF_ISP_GAMMA_OUT_MAX_SAMPLES_V12,
    .compand = false,
};

const rkisp1Controls = ControlInfoMap{
    .map = std.AutoHashMap(&ControlId, ControlInfo){
        .init = {
            &controls.AwbEnable => ControlInfo{ .min = false, .max = true },
            &controls.ColourGains => ControlInfo{ .min = 0.0, .max = 3.996, .def = 1.0 },
            &controls.DebugMetadataEnable => ControlInfo{ .min = false, .max = true, .def = false },
            &controls.Sharpness => ControlInfo{ .min = 0.0, .max = 10.0, .def = 1.0 },
            &controls.draft.NoiseReductionMode => ControlInfo{ .values = controls.draft.NoiseReductionModeValues },
        },
    },
};

pub fn main() void {
    const ipa = IPARkISP1{};
    // Example usage of the IPARkISP1 struct
}

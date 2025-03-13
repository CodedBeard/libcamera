const std = @import("std");
const linux = @cImport({
    @cInclude("linux/intel-ipu3.h");
    @cInclude("linux/v4l2-controls.h");
});

const log = std.log;
const utils = @import("utils");
const controls = @import("controls");
const geometry = @import("geometry");
const framebuffer = @import("framebuffer");
const request = @import("request");
const ipa_interface = @import("ipa/ipa_interface");
const ipa_module_info = @import("ipa/ipa_module_info");
const ipu3_ipa_interface = @import("ipa/ipu3_ipa_interface");
const mapped_framebuffer = @import("mapped_framebuffer");
const yaml_parser = @import("yaml_parser");
const camera_sensor_helper = @import("camera_sensor_helper");
const ipa_context = @import("ipa_context");
const module = @import("module");

const kMinGridWidth = 16;
const kMaxGridWidth = 80;
const kMinGridHeight = 16;
const kMaxGridHeight = 60;
const kMinCellSizeLog2 = 3;
const kMaxCellSizeLog2 = 6;
const kMaxFrameContexts = 16;

pub const IPAIPU3 = struct {
    context: ipa_context.IPAContext,
    camHelper: ?*camera_sensor_helper.CameraSensorHelper,
    sensorCtrls: ControlInfoMap,
    lensCtrls: ControlInfoMap,
    sensorInfo: IPACameraSensorInfo,
    buffers: std.AutoHashMap(u32, mapped_framebuffer.MappedFrameBuffer),

    pub fn init(self: *IPAIPU3, settings: IPASettings, sensorInfo: IPACameraSensorInfo, sensorControls: ControlInfoMap, ipaControls: *ControlInfoMap) !void {
        self.camHelper = try camera_sensor_helper.CameraSensorHelperFactoryBase.create(settings.sensorModel);
        self.context = ipa_context.IPAContext.init(kMaxFrameContexts);
        self.context.configuration.sensor.lineDuration = sensorInfo.minLineLength * 1.0s / sensorInfo.pixelRate;

        var file = try std.fs.File.openRead(settings.configurationFile);
        defer file.close();

        var data = try yaml_parser.parse(file);
        var version = data.get("version").getOptional(u32, 0);
        if (version != 1) {
            return error.InvalidTuningFileVersion;
        }

        if (!data.contains("algorithms")) {
            return error.TuningFileMissingAlgorithms;
        }

        try self.createAlgorithms(self.context, data.get("algorithms"));

        self.updateControls(sensorInfo, sensorControls, ipaControls);
    }

    pub fn start(self: *IPAIPU3) !void {
        self.setControls(0);
    }

    pub fn stop(self: *IPAIPU3) void {
        self.context.frameContexts.clear();
    }

    pub fn configure(self: *IPAIPU3, configInfo: IPAConfigInfo, ipaControls: *ControlInfoMap) !void {
        if (configInfo.sensorControls.empty()) {
            return error.NoSensorControlsProvided;
        }

        self.sensorInfo = configInfo.sensorInfo;
        self.lensCtrls = configInfo.lensControls;

        self.context.activeState = {};
        self.context.configuration = {};
        self.context.frameContexts.clear();

        self.context.configuration.sensor.lineDuration = self.sensorInfo.minLineLength * 1.0s / self.sensorInfo.pixelRate;
        self.context.configuration.sensor.size = self.sensorInfo.outputSize;

        self.sensorCtrls = configInfo.sensorControls;

        self.calculateBdsGrid(configInfo.bdsOutputSize);

        self.updateControls(self.sensorInfo, self.sensorCtrls, ipaControls);

        self.updateSessionConfiguration(self.sensorCtrls);

        for (algo in self.algorithms()) |algorithm| {
            try algorithm.configure(self.context, configInfo);
        }
    }

    pub fn mapBuffers(self: *IPAIPU3, buffers: []IPABuffer) void {
        for (buffer in buffers) |buf| {
            var fb = framebuffer.FrameBuffer.init(buf.planes);
            self.buffers.put(buf.id, mapped_framebuffer.MappedFrameBuffer.init(&fb, mapped_framebuffer.MappedFrameBuffer.MapFlag.ReadWrite));
        }
    }

    pub fn unmapBuffers(self: *IPAIPU3, ids: []u32) void {
        for (id in ids) |bufferId| {
            self.buffers.remove(bufferId);
        }
    }

    pub fn computeParams(self: *IPAIPU3, frame: u32, bufferId: u32) void {
        var it = self.buffers.get(bufferId);
        if (it == null) {
            log.error("Could not find param buffer!");
            return;
        }

        var mem = it.?.planes[0];
        var params = @ptrCast(*linux.ipu3_uapi_params, mem.data());

        params.use = {};

        var frameContext = self.context.frameContexts.get(frame);

        for (algo in self.algorithms()) |algorithm| {
            algorithm.prepare(self.context, frame, frameContext, params);
        }

        self.paramsComputed.emit(frame);
    }

    pub fn processStats(self: *IPAIPU3, frame: u32, frameTimestamp: i64, bufferId: u32, sensorControls: ControlList) void {
        var it = self.buffers.get(bufferId);
        if (it == null) {
            log.error("Could not find stats buffer!");
            return;
        }

        var mem = it.?.planes[0];
        var stats = @ptrCast(*const linux.ipu3_uapi_stats_3a, mem.data());

        var frameContext = self.context.frameContexts.get(frame);

        frameContext.sensor.exposure = sensorControls.get(linux.V4L2_CID_EXPOSURE).get(i32);
        frameContext.sensor.gain = self.camHelper.?.gain(sensorControls.get(linux.V4L2_CID_ANALOGUE_GAIN).get(i32));

        var metadata = ControlList.init(controls.controls);

        for (algo in self.algorithms()) |algorithm| {
            algorithm.process(self.context, frame, frameContext, stats, metadata);
        }

        self.setControls(frame);

        self.metadataReady.emit(frame, metadata);
    }

    pub fn queueRequest(self: *IPAIPU3, frame: u32, controls: ControlList) void {
        var frameContext = self.context.frameContexts.alloc(frame);

        for (algo in self.algorithms()) |algorithm| {
            algorithm.queueRequest(self.context, frame, frameContext, controls);
        }
    }

    fn setControls(self: *IPAIPU3, frame: u32) void {
        var exposure = self.context.activeState.agc.exposure;
        var gain = self.camHelper.?.gainCode(self.context.activeState.agc.gain);

        var ctrls = ControlList.init(self.sensorCtrls);
        ctrls.set(linux.V4L2_CID_EXPOSURE, exposure);
        ctrls.set(linux.V4L2_CID_ANALOGUE_GAIN, gain);

        var lensCtrls = ControlList.init(self.lensCtrls);
        lensCtrls.set(linux.V4L2_CID_FOCUS_ABSOLUTE, @intCast(i32, self.context.activeState.af.focus));

        self.setSensorControls.emit(frame, ctrls, lensCtrls);
    }

    fn updateControls(self: *IPAIPU3, sensorInfo: IPACameraSensorInfo, sensorControls: ControlInfoMap, ipaControls: *ControlInfoMap) void {
        var controls = ControlInfoMap.Map.init();
        var lineDuration = self.context.configuration.sensor.lineDuration.get(std.time.ns);

        var v4l2Exposure = sensorControls.get(linux.V4L2_CID_EXPOSURE).?;
        var minExposure = v4l2Exposure.min().get(i32) * lineDuration;
        var maxExposure = v4l2Exposure.max().get(i32) * lineDuration;
        var defExposure = v4l2Exposure.def().get(i32) * lineDuration;
        controls.put(&controls.ExposureTime, ControlInfo.init(minExposure, maxExposure, defExposure));

        var v4l2HBlank = sensorControls.get(linux.V4L2_CID_HBLANK).?;
        var hblank = v4l2HBlank.def().get(i32);
        var lineLength = sensorInfo.outputSize.width + hblank;

        var v4l2VBlank = sensorControls.get(linux.V4L2_CID_VBLANK).?;
        var frameHeights = [_]u32{
            v4l2VBlank.min().get(i32) + sensorInfo.outputSize.height,
            v4l2VBlank.max().get(i32) + sensorInfo.outputSize.height,
            v4l2VBlank.def().get(i32) + sensorInfo.outputSize.height,
        };

        var frameDurations = [_]i64{0, 0, 0};
        for (i, frameHeight in frameHeights) |i, height| {
            var frameSize = lineLength * height;
            frameDurations[i] = frameSize / (sensorInfo.pixelRate / 1000000);
        }

        controls.put(&controls.FrameDurationLimits, ControlInfo.init(frameDurations[0], frameDurations[1], frameDurations[2]));

        controls.merge(self.context.ctrlMap);
        ipaControls.* = ControlInfoMap.init(controls, controls.controls);
    }

    fn updateSessionConfiguration(self: *IPAIPU3, sensorControls: ControlInfoMap) void {
        var vBlank = sensorControls.get(linux.V4L2_CID_VBLANK).?;
        self.context.configuration.sensor.defVBlank = vBlank.def().get(i32);

        var v4l2Exposure = sensorControls.get(linux.V4L2_CID_EXPOSURE).?;
        var minExposure = v4l2Exposure.min().get(i32);
        var maxExposure = v4l2Exposure.max().get(i32);

        var v4l2Gain = sensorControls.get(linux.V4L2_CID_ANALOGUE_GAIN).?;
        var minGain = v4l2Gain.min().get(i32);
        var maxGain = v4l2Gain.max().get(i32);

        self.context.configuration.agc.minExposureTime = minExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.agc.maxExposureTime = maxExposure * self.context.configuration.sensor.lineDuration;
        self.context.configuration.agc.minAnalogueGain = self.camHelper.?.gain(minGain);
        self.context.configuration.agc.maxAnalogueGain = self.camHelper.?.gain(maxGain);
    }

    fn calculateBdsGrid(self: *IPAIPU3, bdsOutputSize: geometry.Size) void {
        var best = geometry.Size{0, 0};
        var bestLog2 = geometry.Size{0, 0};

        self.context.configuration.grid.bdsOutputSize = bdsOutputSize;

        var minError = std.math.maxInt(u32);
        for (shift in kMinCellSizeLog2..=kMaxCellSizeLog2) |shift| {
            var width = std.math.clamp(bdsOutputSize.width >> shift, kMinGridWidth, kMaxGridWidth);
            width = width << shift;
            var error = utils.abs_diff(width, bdsOutputSize.width);
            if (error >= minError) continue;

            minError = error;
            best.width = width;
            bestLog2.width = shift;
        }

        minError = std.math.maxInt(u32);
        for (shift in kMinCellSizeLog2..=kMaxCellSizeLog2) |shift| {
            var height = std.math.clamp(bdsOutputSize.height >> shift, kMinGridHeight, kMaxGridHeight);
            height = height << shift;
            var error = utils.abs_diff(height, bdsOutputSize.height);
            if (error >= minError) continue;

            minError = error;
            best.height = height;
            bestLog2.height = shift;
        }

        var bdsGrid = &self.context.configuration.grid.bdsGrid;
        bdsGrid.x_start = 0;
        bdsGrid.y_start = 0;
        bdsGrid.width = best.width >> bestLog2.width;
        bdsGrid.block_width_log2 = bestLog2.width;
        bdsGrid.height = best.height >> bestLog2.height;
        bdsGrid.block_height_log2 = bestLog2.height;

        self.context.configuration.grid.stride = utils.alignUp(bdsGrid.width, 4);

        log.debug("Best grid found is: ({d} << {d}) x ({d} << {d})", bdsGrid.width, bdsGrid.block_width_log2, bdsGrid.height, bdsGrid.block_height_log2);
    }
};

pub export fn ipaCreate() *ipa_interface.IPAInterface {
    return IPAIPU3.init();
}

pub export const ipaModuleInfo = ipa_module_info.IPAModuleInfo{
    .api_version = IPA_MODULE_API_VERSION,
    .pipeline_version = 1,
    .pipeline_name = "ipu3",
    .module_name = "ipu3",
};

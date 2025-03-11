const std = @import("std");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");

const FrameLengthsQueueSize = 10;
const defaultAnalogueGain = 1.0;
const defaultExposureTime = 20.0 * std.time.millisecond;
const defaultMinFrameDuration = 1.0 / 30.0 * std.time.second;
const defaultMaxFrameDuration = 250.0 * std.time.second;
const controllerMinFrameDuration = 1.0 / 30.0 * std.time.second;

const ipaControls = std.HashMap([]const u8, libcamera.ControlInfo).init(std.heap.page_allocator);
const ipaColourControls = std.HashMap([]const u8, libcamera.ControlInfo).init(std.heap.page_allocator);
const ipaAfControls = std.HashMap([]const u8, libcamera.ControlInfo).init(std.heap.page_allocator);
const platformControls = std.HashMap([]const u8, libcamera.ControlInfo).init(std.heap.page_allocator);

const IPARPI = libcamera.LogCategory("IPARPI");

const IpaBase = struct {
    controller: RPiController.Controller,
    frameLengths: [FrameLengthsQueueSize]std.time.Duration,
    statsMetadataOutput: bool,
    stitchSwapBuffers: bool,
    frameCount: u32,
    mistrustCount: u32,
    lastRunTimestamp: i64,
    firstStart: bool,
    flickerState: FlickerState,
    cnnEnableInputTensor: bool,
    helper: ?*RPiController.CamHelper,
    lensPresent: bool,
    sensorCtrls: libcamera.ControlList,
    lensCtrls: libcamera.ControlList,
    libcameraMetadata: libcamera.ControlList,
    mode: CameraMode,
    monoSensor: bool,
    dropFrameCount: u32,
    lastTimeout: std.time.Duration,
    minFrameDuration: std.time.Duration,
    maxFrameDuration: std.time.Duration,
    hdrStatus: HdrStatus,
    processPending: bool,
    rpiMetadata: [10]RPiController.Metadata,

    pub fn init() IpaBase {
        return IpaBase{
            .controller = RPiController.Controller.init(),
            .frameLengths = [_]std.time.Duration{0} ** FrameLengthsQueueSize,
            .statsMetadataOutput = false,
            .stitchSwapBuffers = false,
            .frameCount = 0,
            .mistrustCount = 0,
            .lastRunTimestamp = 0,
            .firstStart = true,
            .flickerState = FlickerState.init(),
            .cnnEnableInputTensor = false,
            .helper = null,
            .lensPresent = false,
            .sensorCtrls = libcamera.ControlList.init(),
            .lensCtrls = libcamera.ControlList.init(),
            .libcameraMetadata = libcamera.ControlList.init(),
            .mode = CameraMode.init(),
            .monoSensor = false,
            .dropFrameCount = 0,
            .lastTimeout = 0,
            .minFrameDuration = defaultMinFrameDuration,
            .maxFrameDuration = defaultMaxFrameDuration,
            .hdrStatus = HdrStatus.init(),
            .processPending = false,
            .rpiMetadata = [_]RPiController.Metadata{RPiController.Metadata.init()} ** 10,
        };
    }

    pub fn deinit(self: *IpaBase) void {}

    pub fn init(self: *IpaBase, settings: IPASettings, params: InitParams, result: *InitResult) !void {
        self.helper = try RPiController.CamHelper.create(settings.sensorModel);
        if (self.helper == null) {
            return error.InvalidArgument;
        }

        result.sensorConfig.sensorMetadata = self.helper.sensorEmbeddedDataPresent();

        try self.controller.read(settings.configurationFile);

        self.lensPresent = params.lensPresent;

        self.controller.initialise();
        self.helper.setHwConfig(self.controller.getHardwareConfig());

        var ctrlMap = ipaControls;
        if (self.lensPresent) {
            ctrlMap.merge(ipaAfControls);
        }

        const platformCtrlsIt = platformControls.get(self.controller.getTarget());
        if (platformCtrlsIt) |platformCtrls| {
            ctrlMap.merge(platformCtrls);
        }

        self.monoSensor = params.sensorInfo.cfaPattern == libcamera.properties.draft.ColorFilterArrangementEnum.MONO;
        if (!self.monoSensor) {
            ctrlMap.merge(ipaColourControls);
        }

        result.controlInfo = libcamera.ControlInfoMap(ctrlMap, libcamera.controls.controls);

        try self.platformInit(params, result);
    }

    pub fn configure(self: *IpaBase, sensorInfo: IPACameraSensorInfo, params: ConfigParams, result: *ConfigResult) !void {
        self.sensorCtrls = params.sensorControls;

        if (!self.validateSensorControls()) {
            return error.InvalidArgument;
        }

        if (self.lensPresent) {
            self.lensCtrls = params.lensControls;
            if (!self.validateLensControls()) {
                self.lensPresent = false;
            }
        }

        self.libcameraMetadata = libcamera.ControlList(libcamera.controls.controls);

        self.setMode(sensorInfo);

        self.mode.transform = @intCast(libcamera.Transform, params.transform);

        self.helper.setCameraMode(self.mode);

        var ctrls = libcamera.ControlList(self.sensorCtrls);

        result.modeSensitivity = self.mode.sensitivity;

        if (self.firstStart) {
            self.applyFrameDurations(defaultMinFrameDuration, defaultMaxFrameDuration);

            var agcStatus = RPiController.AgcStatus.init();
            agcStatus.exposureTime = defaultExposureTime;
            agcStatus.analogueGain = defaultAnalogueGain;
            self.applyAGC(&agcStatus, &ctrls);

            if (self.lensPresent) {
                const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                if (af) {
                    const defaultPos = ipaAfControls.get(libcamera.controls.LensPosition).?.def().get(f32);
                    var lensCtrl = libcamera.ControlList(self.lensCtrls);
                    var hwpos: i32 = 0;
                    af.setLensPosition(defaultPos, &hwpos);
                    lensCtrl.set(libcamera.V4L2_CID_FOCUS_ABSOLUTE, hwpos);
                    result.lensControls = lensCtrl;
                }
            }
        }

        result.sensorControls = ctrls;

        var ctrlMap = ipaControls;
        ctrlMap[libcamera.controls.FrameDurationLimits] = libcamera.ControlInfo(
            @intCast(i64, self.mode.minFrameDuration.get(std.time.microsecond)),
            @intCast(i64, self.mode.maxFrameDuration.get(std.time.microsecond)),
            @intCast(i64, defaultMinFrameDuration.get(std.time.microsecond))
        );

        ctrlMap[libcamera.controls.AnalogueGain] = libcamera.ControlInfo(
            @intCast(f32, self.mode.minAnalogueGain),
            @intCast(f32, self.mode.maxAnalogueGain),
            @intCast(f32, defaultAnalogueGain)
        );

        ctrlMap[libcamera.controls.ExposureTime] = libcamera.ControlInfo(
            @intCast(i32, self.mode.minExposureTime.get(std.time.microsecond)),
            @intCast(i32, self.mode.maxExposureTime.get(std.time.microsecond)),
            @intCast(i32, defaultExposureTime.get(std.time.microsecond))
        );

        if (!self.monoSensor) {
            ctrlMap.merge(ipaColourControls);
        }

        if (self.lensPresent) {
            ctrlMap.merge(ipaAfControls);
        }

        result.controlInfo = libcamera.ControlInfoMap(ctrlMap, libcamera.controls.controls);

        try self.platformConfigure(params, result);
    }

    pub fn start(self: *IpaBase, controls: libcamera.ControlList, result: *StartResult) void {
        var metadata = RPiController.Metadata.init();

        if (controls.len > 0) {
            self.applyControls(controls);
        }

        self.controller.switchMode(self.mode, &metadata);

        self.lastTimeout = 0;
        self.frameLengths = [_]std.time.Duration{0} ** FrameLengthsQueueSize;

        var agcStatus = RPiController.AgcStatus.init();
        agcStatus.exposureTime = 0;
        agcStatus.analogueGain = 0;

        metadata.get("agc.status", &agcStatus);
        if (agcStatus.exposureTime != 0 and agcStatus.analogueGain != 0) {
            var ctrls = libcamera.ControlList(self.sensorCtrls);
            self.applyAGC(&agcStatus, &ctrls);
            result.controls = ctrls;
            self.setCameraTimeoutValue();
        }

        self.hdrStatus = agcStatus.hdr;

        self.frameCount = 0;
        if (self.firstStart) {
            self.dropFrameCount = self.helper.hideFramesStartup();
            self.mistrustCount = self.helper.mistrustFramesStartup();

            var agcConvergenceFrames = 0;
            const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
            if (agc) {
                agcConvergenceFrames = agc.getConvergenceFrames();
                if (agcConvergenceFrames != 0) {
                    agcConvergenceFrames += self.mistrustCount;
                }
            }

            var awbConvergenceFrames = 0;
            const awb = self.controller.getAlgorithm("awb").? as *RPiController.AwbAlgorithm;
            if (awb) {
                awbConvergenceFrames = awb.getConvergenceFrames();
                if (awbConvergenceFrames != 0) {
                    awbConvergenceFrames += self.mistrustCount;
                }
            }

            self.dropFrameCount = std.math.max(std.math.max(self.dropFrameCount, agcConvergenceFrames), awbConvergenceFrames);
        } else {
            self.dropFrameCount = self.helper.hideFramesModeSwitch();
            self.mistrustCount = self.helper.mistrustFramesModeSwitch();
        }

        result.dropFrameCount = self.dropFrameCount;

        self.firstStart = false;
        self.lastRunTimestamp = 0;

        self.platformStart(controls, result);
    }

    pub fn mapBuffers(self: *IpaBase, buffers: []libcamera.IPABuffer) void {
        for (buffers) |buffer| {
            const fb = libcamera.FrameBuffer(buffer.planes);
            self.buffers[buffer.id] = libcamera.MappedFrameBuffer(&fb, libcamera.MappedFrameBuffer.MapFlag.ReadWrite);
        }
    }

    pub fn unmapBuffers(self: *IpaBase, ids: []u32) void {
        for (ids) |id| {
            self.buffers.remove(id);
        }
    }

    pub fn prepareIsp(self: *IpaBase, params: PrepareParams) void {
        self.applyControls(params.requestControls);

        const frameTimestamp = params.sensorControls.get(libcamera.controls.SensorTimestamp).?.get(i64);
        const ipaContext = params.ipaContext % self.rpiMetadata.len;
        var rpiMetadata = self.rpiMetadata[ipaContext];
        var embeddedBuffer: []u8 = &[_]u8{};

        rpiMetadata.clear();
        self.fillDeviceStatus(params.sensorControls, ipaContext);
        self.fillSyncParams(params, ipaContext);

        if (params.buffers.embedded) |embedded| {
            embeddedBuffer = self.buffers[embedded].planes[0];
        }

        var agcStatus = RPiController.AgcStatus.init();
        var hdrChange = false;
        const delayedMetadata = self.rpiMetadata[params.delayContext];
        if (delayedMetadata.get("agc.status", &agcStatus) == 0) {
            rpiMetadata.set("agc.delayed_status", agcStatus);
            hdrChange = agcStatus.hdr.mode != self.hdrStatus.mode;
            self.hdrStatus = agcStatus.hdr;
        }

        self.helper.prepare(embeddedBuffer, &rpiMetadata);

        const delta = (frameTimestamp - self.lastRunTimestamp) * std.time.nanosecond;
        if (self.lastRunTimestamp != 0 and self.frameCount > self.dropFrameCount and delta < controllerMinFrameDuration * 0.9 and not hdrChange) {
            const lastMetadata = self.rpiMetadata[(ipaContext != 0) ? ipaContext : self.rpiMetadata.len - 1];
            rpiMetadata.mergeCopy(lastMetadata);
            self.processPending = false;
        } else {
            self.processPending = true;
            self.lastRunTimestamp = frameTimestamp;
        }

        if (self.controller.getHardwareConfig().statsInline) {
            self.processStats(ProcessParams{ .buffers = params.buffers, .ipaContext = params.ipaContext });
        }

        if (self.processPending) {
            self.controller.prepare(&rpiMetadata);
            self.platformPrepareIsp(params, rpiMetadata);
        }

        self.frameCount += 1;

        if (self.controller.getHardwareConfig().statsInline) {
            self.reportMetadata(ipaContext);
        }

        self.prepareIspComplete.emit(params.buffers, self.stitchSwapBuffers);
    }

    pub fn processStats(self: *IpaBase, params: ProcessParams) void {
        const ipaContext = params.ipaContext % self.rpiMetadata.len;

        if (self.processPending and self.frameCount >= self.mistrustCount) {
            var rpiMetadata = self.rpiMetadata[ipaContext];

            const it = self.buffers.get(params.buffers.stats);
            if (it == null) {
                return;
            }

            const statistics = self.platformProcessStats(it.?.planes[0]);

            rpiMetadata.set("focus.status", statistics.focusRegions);

            self.helper.process(statistics, &rpiMetadata);
            self.controller.process(statistics, &rpiMetadata);

            var offset = std.time.Duration(0);
            const syncStatus = rpiMetadata.get("sync.status", SyncStatus);
            if (syncStatus) |status| {
                if (self.minFrameDuration != self.maxFrameDuration) {
                    return;
                }
                offset = status.frameDurationOffset;

                self.libcameraMetadata.set(libcamera.controls.rpi.SyncReady, status.ready);
                if (status.timerKnown) {
                    self.libcameraMetadata.set(libcamera.controls.rpi.SyncTimer, status.timerValue);
                }
            }

            const agcStatus = rpiMetadata.get("agc.status", RPiController.AgcStatus);
            if (agcStatus) |status| {
                var ctrls = libcamera.ControlList(self.sensorCtrls);
                self.applyAGC(status, &ctrls, offset);
                self.setDelayedControls.emit(ctrls, ipaContext);
                self.setCameraTimeoutValue();
            }
        }

        if (!self.controller.getHardwareConfig().statsInline) {
            self.reportMetadata(ipaContext);
        }

        self.processStatsComplete.emit(params.buffers);
    }

    fn setMode(self: *IpaBase, sensorInfo: IPACameraSensorInfo) void {
        self.mode.bitdepth = sensorInfo.bitsPerPixel;
        self.mode.width = sensorInfo.outputSize.width;
        self.mode.height = sensorInfo.outputSize.height;
        self.mode.sensorWidth = sensorInfo.activeAreaSize.width;
        self.mode.sensorHeight = sensorInfo.activeAreaSize.height;
        self.mode.cropX = sensorInfo.analogCrop.x;
        self.mode.cropY = sensorInfo.analogCrop.y;
        self.mode.pixelRate = sensorInfo.pixelRate;

        self.mode.scaleX = sensorInfo.analogCrop.width / sensorInfo.outputSize.width;
        self.mode.scaleY = sensorInfo.analogCrop.height / sensorInfo.outputSize.height;

        self.mode.binX = std.math.min(2, @intCast(i32, self.mode.scaleX));
        self.mode.binY = std.math.min(2, @intCast(i32, self.mode.scaleY));

        self.mode.noiseFactor = std.math.sqrt(self.mode.binX * self.mode.binY);

        self.mode.minLineLength = sensorInfo.minLineLength * (1.0 / sensorInfo.pixelRate);
        self.mode.maxLineLength = sensorInfo.maxLineLength * (1.0 / sensorInfo.pixelRate);

        const minPixelTime = self.controller.getHardwareConfig().minPixelProcessingTime;
        const pixelTime = self.mode.minLineLength / self.mode.width;
        if (minPixelTime != 0 and pixelTime < minPixelTime) {
            const adjustedLineLength = minPixelTime * self.mode.width;
            if (adjustedLineLength <= self.mode.maxLineLength) {
                self.mode.minLineLength = adjustedLineLength;
            } else {
                return;
            }
        }

        self.mode.minFrameLength = sensorInfo.minFrameLength;
        self.mode.maxFrameLength = sensorInfo.maxFrameLength;

        self.mode.minFrameDuration = self.mode.minFrameLength * self.mode.minLineLength;
        self.mode.maxFrameDuration = self.mode.maxFrameLength * self.mode.maxLineLength;

        self.mode.sensitivity = self.helper.getModeSensitivity(self.mode);

        const gainCtrl = self.sensorCtrls.get(libcamera.V4L2_CID_ANALOGUE_GAIN).?;
        const exposureTimeCtrl = self.sensorCtrls.get(libcamera.V4L2_CID_EXPOSURE).?;

        self.mode.minAnalogueGain = self.helper.gain(gainCtrl.min().get(i32));
        self.mode.maxAnalogueGain = self.helper.gain(gainCtrl.max().get(i32));

        self.helper.setCameraMode(self.mode);

        self.mode.minExposureTime = self.helper.exposure(exposureTimeCtrl.min().get(i32), self.mode.minLineLength);
        self.mode.maxExposureTime = std.time.Duration.max();
        self.helper.getBlanking(&self.mode.maxExposureTime, self.mode.minFrameDuration, self.mode.maxFrameDuration);
    }

    fn setCameraTimeoutValue(self: *IpaBase) void {
        const max = std.math.max(self.frameLengths);
        if (max != self.lastTimeout) {
            self.setCameraTimeout.emit(max.get(std.time.millisecond));
            self.lastTimeout = max;
        }
    }

    fn validateSensorControls(self: *IpaBase) bool {
        const ctrls = [_]u32{
            libcamera.V4L2_CID_ANALOGUE_GAIN,
            libcamera.V4L2_CID_EXPOSURE,
            libcamera.V4L2_CID_VBLANK,
            libcamera.V4L2_CID_HBLANK,
        };

        for (ctrls) |c| {
            if (self.sensorCtrls.get(c) == null) {
                return false;
            }
        }

        return true;
    }

    fn validateLensControls(self: *IpaBase) bool {
        if (self.lensCtrls.get(libcamera.V4L2_CID_FOCUS_ABSOLUTE) == null) {
            return false;
        }

        return true;
    }

    fn applyControls(self: *IpaBase, controls: libcamera.ControlList) void {
        self.libcameraMetadata.clear();

        if (controls.get(libcamera.controls.AF_MODE)) |afMode| {
            const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
            if (af == null) {
                return;
            }

            const mode = AfModeTable.get(afMode.get(i32));
            if (mode) |m| {
                af.setMode(m);
            }
        }

        for (controls) |ctrl| {
            switch (ctrl.key) {
                libcamera.controls.AE_ENABLE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    if (ctrl.value.get(bool)) {
                        agc.enableAuto();
                    } else {
                        agc.disableAuto();
                    }

                    self.libcameraMetadata.set(libcamera.controls.AeEnable, ctrl.value.get(bool));
                },
                libcamera.controls.EXPOSURE_TIME => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    agc.setFixedExposureTime(0, ctrl.value.get(i32) * std.time.microsecond);

                    self.libcameraMetadata.set(libcamera.controls.ExposureTime, ctrl.value.get(i32));
                },
                libcamera.controls.ANALOGUE_GAIN => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    agc.setFixedAnalogueGain(0, ctrl.value.get(f32));

                    self.libcameraMetadata.set(libcamera.controls.AnalogueGain, ctrl.value.get(f32));
                },
                libcamera.controls.AE_METERING_MODE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const idx = ctrl.value.get(i32);
                    const mode = MeteringModeTable.get(idx);
                    if (mode) |m| {
                        agc.setMeteringMode(m);
                        self.libcameraMetadata.set(libcamera.controls.AeMeteringMode, idx);
                    }
                },
                libcamera.controls.AE_CONSTRAINT_MODE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const idx = ctrl.value.get(i32);
                    const mode = ConstraintModeTable.get(idx);
                    if (mode) |m| {
                        agc.setConstraintMode(m);
                        self.libcameraMetadata.set(libcamera.controls.AeConstraintMode, idx);
                    }
                },
                libcamera.controls.AE_EXPOSURE_MODE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const idx = ctrl.value.get(i32);
                    const mode = ExposureModeTable.get(idx);
                    if (mode) |m| {
                        agc.setExposureMode(m);
                        self.libcameraMetadata.set(libcamera.controls.AeExposureMode, idx);
                    }
                },
                libcamera.controls.EXPOSURE_VALUE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const ev = std.math.pow(2.0, ctrl.value.get(f32));
                    agc.setEv(0, ev);
                    self.libcameraMetadata.set(libcamera.controls.ExposureValue, ctrl.value.get(f32));
                },
                libcamera.controls.AE_FLICKER_MODE => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const mode = ctrl.value.get(i32);
                    switch (mode) {
                        libcamera.controls.FlickerOff => {
                            agc.setFlickerPeriod(0);
                        },
                        libcamera.controls.FlickerManual => {
                            agc.setFlickerPeriod(self.flickerState.manualPeriod);
                        },
                        else => {
                            return;
                        }
                    }

                    self.flickerState.mode = mode;
                },
                libcamera.controls.AE_FLICKER_PERIOD => {
                    const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                    if (agc == null) {
                        return;
                    }

                    const manualPeriod = ctrl.value.get(i32);
                    self.flickerState.manualPeriod = manualPeriod * std.time.microsecond;

                    if (self.flickerState.mode == libcamera.controls.FlickerManual) {
                        agc.setFlickerPeriod(self.flickerState.manualPeriod);
                    }
                },
                libcamera.controls.AWB_ENABLE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const awb = self.controller.getAlgorithm("awb").? as *RPiController.AwbAlgorithm;
                    if (awb == null) {
                        return;
                    }

                    if (ctrl.value.get(bool)) {
                        awb.enableAuto();
                    } else {
                        awb.disableAuto();
                    }

                    self.libcameraMetadata.set(libcamera.controls.AwbEnable, ctrl.value.get(bool));
                },
                libcamera.controls.AWB_MODE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const awb = self.controller.getAlgorithm("awb").? as *RPiController.AwbAlgorithm;
                    if (awb == null) {
                        return;
                    }

                    const idx = ctrl.value.get(i32);
                    const mode = AwbModeTable.get(idx);
                    if (mode) |m| {
                        awb.setMode(m);
                        self.libcameraMetadata.set(libcamera.controls.AwbMode, idx);
                    }
                },
                libcamera.controls.COLOUR_GAINS => {
                    if (self.monoSensor) {
                        break;
                    }

                    const gains = ctrl.value.get([]const f32);
                    const awb = self.controller.getAlgorithm("awb").? as *RPiController.AwbAlgorithm;
                    if (awb == null) {
                        return;
                    }

                    awb.setManualGains(gains[0], gains[1]);
                    if (gains[0] != 0 and gains[1] != 0) {
                        self.libcameraMetadata.set(libcamera.controls.ColourGains, gains);
                    }
                },
                libcamera.controls.COLOUR_TEMPERATURE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const temperatureK = ctrl.value.get(i32);
                    const awb = self.controller.getAlgorithm("awb").? as *RPiController.AwbAlgorithm;
                    if (awb == null) {
                        return;
                    }

                    awb.setColourTemperature(temperatureK);
                },
                libcamera.controls.BRIGHTNESS => {
                    const contrast = self.controller.getAlgorithm("contrast").? as *RPiController.ContrastAlgorithm;
                    if (contrast == null) {
                        return;
                    }

                    contrast.setBrightness(ctrl.value.get(f32) * 65536);
                    self.libcameraMetadata.set(libcamera.controls.Brightness, ctrl.value.get(f32));
                },
                libcamera.controls.CONTRAST => {
                    const contrast = self.controller.getAlgorithm("contrast").? as *RPiController.ContrastAlgorithm;
                    if (contrast == null) {
                        return;
                    }

                    contrast.setContrast(ctrl.value.get(f32));
                    self.libcameraMetadata.set(libcamera.controls.Contrast, ctrl.value.get(f32));
                },
                libcamera.controls.SATURATION => {
                    if (self.monoSensor) {
                        break;
                    }

                    const ccm = self.controller.getAlgorithm("ccm").? as *RPiController.CcmAlgorithm;
                    if (ccm == null) {
                        return;
                    }

                    ccm.setSaturation(ctrl.value.get(f32));
                    self.libcameraMetadata.set(libcamera.controls.Saturation, ctrl.value.get(f32));
                },
                libcamera.controls.SHARPNESS => {
                    const sharpen = self.controller.getAlgorithm("sharpen").? as *RPiController.SharpenAlgorithm;
                    if (sharpen == null) {
                        return;
                    }

                    sharpen.setStrength(ctrl.value.get(f32));
                    self.libcameraMetadata.set(libcamera.controls.Sharpness, ctrl.value.get(f32));
                },
                libcamera.controls.rpi.SCALER_CROPS,
                libcamera.controls.SCALER_CROP => {
                    break;
                },
                libcamera.controls.FRAME_DURATION_LIMITS => {
                    const frameDurations = ctrl.value.get([]const i64);
                    self.applyFrameDurations(frameDurations[0] * std.time.microsecond, frameDurations[1] * std.time.microsecond);
                },
                libcamera.controls.draft.NOISE_REDUCTION_MODE => {
                    self.libcameraMetadata.set(libcamera.controls.draft.NoiseReductionMode, ctrl.value.get(i32));
                },
                libcamera.controls.AF_RANGE => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null) {
                        return;
                    }

                    const range = AfRangeTable.get(ctrl.value.get(i32));
                    if (range) |r| {
                        af.setRange(r);
                    }
                },
                libcamera.controls.AF_SPEED => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null) {
                        return;
                    }

                    const speed = (ctrl.value.get(i32) == libcamera.controls.AfSpeedFast) ? RPiController.AfAlgorithm.AfSpeedFast : RPiController.AfAlgorithm.AfSpeedNormal;
                    af.setSpeed(speed);
                },
                libcamera.controls.AF_METERING => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null) {
                        return;
                    }

                    af.setMetering(ctrl.value.get(i32) == libcamera.controls.AfMeteringWindows);
                },
                libcamera.controls.AF_WINDOWS => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null) {
                        return;
                    }

                    af.setWindows(ctrl.value.get([]const libcamera.Rectangle));
                },
                libcamera.controls.AF_PAUSE => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null or af.getMode() != RPiController.AfAlgorithm.AfModeContinuous) {
                        return;
                    }

                    const pause = AfPauseTable.get(ctrl.value.get(i32));
                    if (pause) |p| {
                        af.pause(p);
                    }
                },
                libcamera.controls.AF_TRIGGER => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af == null or af.getMode() != RPiController.AfAlgorithm.AfModeAuto) {
                        return;
                    }

                    if (ctrl.value.get(i32) == libcamera.controls.AfTriggerStart) {
                        af.triggerScan();
                    } else {
                        af.cancelScan();
                    }
                },
                libcamera.controls.LENS_POSITION => {
                    const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
                    if (af) |a| {
                        var hwpos: i32 = 0;
                        if (a.setLensPosition(ctrl.value.get(f32), &hwpos)) {
                            var lensCtrls = libcamera.ControlList(self.lensCtrls);
                            lensCtrls.set(libcamera.V4L2_CID_FOCUS_ABSOLUTE, hwpos);
                            self.setLensControls.emit(lensCtrls);
                        }
                    }
                },
                libcamera.controls.HDR_MODE => {
                    const hdr = self.controller.getAlgorithm("hdr").? as *RPiController.HdrAlgorithm;
                    if (hdr == null) {
                        return;
                    }

                    const mode = HdrModeTable.get(ctrl.value.get(i32));
                    if (mode) |m| {
                        const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
                        if (agc == null) {
                            return;
                        }

                        if (hdr.setMode(m) == 0) {
                            agc.setActiveChannels(hdr.getChannels());

                            const contrast = self.controller.getAlgorithm("contrast").? as *RPiController.ContrastAlgorithm;
                            if (contrast) |c| {
                                if (m == "Off") {
                                    c.restoreCe();
                                } else {
                                    c.enableCe(false);
                                }
                            }

                            const denoise = self.controller.getAlgorithm("denoise").? as *RPiController.DenoiseAlgorithm;
                            if (denoise) |d| {
                                if (m == "Night") {
                                    d.setConfig("night");
                                } else if (m == "SingleExposure") {
                                    d.setConfig("hdr");
                                } else {
                                    d.setConfig("normal");
                                }
                            }
                        }
                    }
                },
                libcamera.controls.rpi.STATS_OUTPUT_ENABLE => {
                    self.statsMetadataOutput = ctrl.value.get(bool);
                },
                libcamera.controls.rpi.CNN_ENABLE_INPUT_TENSOR => {
                    self.cnnEnableInputTensor = ctrl.value.get(bool);
                },
                libcamera.controls.rpi.SYNC_MODE => {
                    const sync = self.controller.getAlgorithm("sync").? as *RPiController.SyncAlgorithm;
                    if (sync) |s| {
                        const mode = ctrl.value.get(i32);
                        var m = RPiController.SyncAlgorithm.Mode.Off;
                        if (mode == libcamera.controls.rpi.SyncModeServer) {
                            m = RPiController.SyncAlgorithm.Mode.Server;
                        } else if (mode == libcamera.controls.rpi.SyncModeClient) {
                            m = RPiController.SyncAlgorithm.Mode.Client;
                        }
                        s.setMode(m);
                    }
                },
                libcamera.controls.rpi.SYNC_FRAMES => {
                    const sync = self.controller.getAlgorithm("sync").? as *RPiController.SyncAlgorithm;
                    if (sync) |s| {
                        const frames = ctrl.value.get(i32);
                        if (frames > 0) {
                            s.setReadyFrame(frames);
                        }
                    }
                },
                else => {
                    break;
                }
            }
        }

        self.handleControls(controls);
    }

    fn fillDeviceStatus(self: *IpaBase, sensorControls: libcamera.ControlList, ipaContext: u32) void {
        var deviceStatus = RPiController.DeviceStatus.init();

        const exposureLines = sensorControls.get(libcamera.V4L2_CID_EXPOSURE).?.get(i32);
        const gainCode = sensorControls.get(libcamera.V4L2_CID_ANALOGUE_GAIN).?.get(i32);
        const vblank = sensorControls.get(libcamera.V4L2_CID_VBLANK).?.get(i32);
        const hblank = sensorControls.get(libcamera.V4L2_CID_HBLANK).?.get(i32);

        deviceStatus.lineLength = self.helper.hblankToLineLength(hblank);
        deviceStatus.exposureTime = self.helper.exposure(exposureLines, deviceStatus.lineLength);
        deviceStatus.analogueGain = self.helper.gain(gainCode);
        deviceStatus.frameLength = self.mode.height + vblank;

        const af = self.controller.getAlgorithm("af").? as *RPiController.AfAlgorithm;
        if (af) |a| {
            deviceStatus.lensPosition = a.getLensPosition();
        }

        self.rpiMetadata[ipaContext].set("device.status", deviceStatus);
    }

    fn fillSyncParams(self: *IpaBase, params: PrepareParams, ipaContext: u32) void {
        const sync = self.controller.getAlgorithm("sync").? as *RPiController.SyncAlgorithm;
        if (sync == null) {
            return;
        }

        var syncParams = RPiController.SyncParams.init();
        syncParams.wallClock = params.sensorControls.get(libcamera.controls.FrameWallClock).?.get(i64);
        syncParams.sensorTimestamp = params.sensorControls.get(libcamera.controls.SensorTimestamp).?.get(i64);
        self.rpiMetadata[ipaContext].set("sync.params", syncParams);
    }

    fn reportMetadata(self: *IpaBase, ipaContext: u32) void {
        var rpiMetadata = self.rpiMetadata[ipaContext];
        const lock = rpiMetadata.lock();

        const deviceStatus = rpiMetadata.getLocked("device.status", RPiController.DeviceStatus);
        if (deviceStatus) |status| {
            self.libcameraMetadata.set(libcamera.controls.ExposureTime, status.exposureTime.get(std.time.microsecond));
            self.libcameraMetadata.set(libcamera.controls.AnalogueGain, status.analogueGain);
            self.libcameraMetadata.set(libcamera.controls.FrameDuration, self.helper.exposure(status.frameLength, status.lineLength).get(std.time.microsecond));
            if (status.sensorTemperature) |temp| {
                self.libcameraMetadata.set(libcamera.controls.SensorTemperature, temp);
            }
            if (status.lensPosition) |pos| {
                self.libcameraMetadata.set(libcamera.controls.LensPosition, pos);
            }
        }

        const agcPrepareStatus = rpiMetadata.getLocked("agc.prepare_status", RPiController.AgcPrepareStatus);
        if (agcPrepareStatus) |status| {
            self.libcameraMetadata.set(libcamera.controls.AeLocked, status.locked);
            self.libcameraMetadata.set(libcamera.controls.DigitalGain, status.digitalGain);
        }

        const luxStatus = rpiMetadata.getLocked("lux.status", RPiController.LuxStatus);
        if (luxStatus) |status| {
            self.libcameraMetadata.set(libcamera.controls.Lux, status.lux);
        }

        const awbStatus = rpiMetadata.getLocked("awb.status", RPiController.AwbStatus);
        if (awbStatus) |status| {
            self.libcameraMetadata.set(libcamera.controls.ColourGains, []f32{ @intCast(f32, status.gainR), @intCast(f32, status.gainB) });
            self.libcameraMetadata.set(libcamera.controls.ColourTemperature, status.temperatureK);
        }

        const blackLevelStatus = rpiMetadata.getLocked("black_level.status", RPiController.BlackLevelStatus);
        if (blackLevelStatus) |status| {
            self.libcameraMetadata.set(libcamera.controls.SensorBlackLevels, []i32{ @intCast(i32, status.blackLevelR), @intCast(i32, status.blackLevelG), @intCast(i32, status.blackLevelG), @intCast(i32, status.blackLevelB) });
        }

        const focusStatus = rpiMetadata.getLocked("focus.status", RPiController.FocusRegions);
        if (focusStatus) |status| {
            const size = status.size();
            const rows = size.height;
            const cols = size.width;

            var sum: u64 = 0;
            var numRegions: u32 = 0;
            for (rows / 3..rows - rows / 3) |r| {
                for (cols / 4..cols - cols / 4) |c| {
                    sum += status.get({ .x = c, .y = r }).val;
                    numRegions += 1;
                }
            }

            const focusFoM = sum / numRegions;
            self.libcameraMetadata.set(libcamera.controls.FocusFoM, focusFoM);
        }

        const ccmStatus = rpiMetadata.getLocked("ccm.status", RPiController.CcmStatus);
        if (ccmStatus) |status| {
            var m: [9]f32 = undefined;
            for (0..9) |i| {
                m[i] = status.matrix[i];
            }
            self.libcameraMetadata.set(libcamera.controls.ColourCorrectionMatrix, m);
        }

        const afStatus = rpiMetadata.getLocked("af.status", RPiController.AfStatus);
        if (afStatus) |status| {
            var s: i32 = 0;
            var p: i32 = 0;
            switch (status.state) {
                RPiController.AfState.Scanning => {
                    s = libcamera.controls.AfStateScanning;
                },
                RPiController.AfState.Focused => {
                    s = libcamera.controls.AfStateFocused;
                },
                RPiController.AfState.Failed => {
                    s = libcamera.controls.AfStateFailed;
                },
                else => {
                    s = libcamera.controls.AfStateIdle;
                }
            }
            switch (status.pauseState) {
                RPiController.AfPauseState.Pausing => {
                    p = libcamera.controls.AfPauseStatePausing;
                },
                RPiController.AfPauseState.Paused => {
                    p = libcamera.controls.AfPauseStatePaused;
                },
                else => {
                    p = libcamera.controls.AfPauseStateRunning;
                }
            }
            self.libcameraMetadata.set(libcamera.controls.AfState, s);
            self.libcameraMetadata.set(libcamera.controls.AfPauseState, p);
        }

        const agcStatus = rpiMetadata.getLocked("agc.delayed_status", RPiController.AgcStatus);
        const hdrStatus = agcStatus ? agcStatus.hdr : self.hdrStatus;
        if (hdrStatus.mode != "" and hdrStatus.mode != "Off") {
            var hdrMode: i32 = libcamera.controls.HdrModeOff;
            for (HdrModeTable) |entry| {
                if (hdrStatus.mode == entry.value) {
                    hdrMode = entry.key;
                    break;
                }
            }
            self.libcameraMetadata.set(libcamera.controls.HdrMode, hdrMode);

            if (hdrStatus.channel == "short") {
                self.libcameraMetadata.set(libcamera.controls.HdrChannel, libcamera.controls.HdrChannelShort);
            } else if (hdrStatus.channel == "long") {
                self.libcameraMetadata.set(libcamera.controls.HdrChannel, libcamera.controls.HdrChannelLong);
            } else if (hdrStatus.channel == "medium") {
                self.libcameraMetadata.set(libcamera.controls.HdrChannel, libcamera.controls.HdrChannelMedium);
            } else {
                self.libcameraMetadata.set(libcamera.controls.HdrChannel, libcamera.controls.HdrChannelNone);
            }
        }

        const inputTensor = rpiMetadata.getLocked("cnn.input_tensor", std.mem.Allocator);
        if (self.cnnEnableInputTensor and inputTensor) |tensor| {
            const size = rpiMetadata.getLocked("cnn.input_tensor_size", u32).?;
            const span = std.mem.span(tensor, size);
            self.libcameraMetadata.set(libcamera.controls.rpi.CnnInputTensor, span);
            rpiMetadata.eraseLocked("cnn.input_tensor");
        }

        const inputTensorInfo = rpiMetadata.getLocked("cnn.input_tensor_info", RPiController.CnnInputTensorInfo);
        if (inputTensorInfo) |info| {
            const span = std.mem.span(info, 1);
            self.libcameraMetadata.set(libcamera.controls.rpi.CnnInputTensorInfo, span);
        }

        const outputTensor = rpiMetadata.getLocked("cnn.output_tensor", std.mem.Allocator);
        if (outputTensor) |tensor| {
            const size = rpiMetadata.getLocked("cnn.output_tensor_size", u32).?;
            const span = std.mem.span(tensor, size);
            self.libcameraMetadata.set(libcamera.controls.rpi.CnnOutputTensor, span);
            rpiMetadata.eraseLocked("cnn.output_tensor");
        }

        const outputTensorInfo = rpiMetadata.getLocked("cnn.output_tensor_info", RPiController.CnnOutputTensorInfo);
        if (outputTensorInfo) |info| {
            const span = std.mem.span(info, 1);
            self.libcameraMetadata.set(libcamera.controls.rpi.CnnOutputTensorInfo, span);
        }

        const kpiInfo = rpiMetadata.getLocked("cnn.kpi_info", RPiController.CnnKpiInfo);
        if (kpiInfo) |info| {
            self.libcameraMetadata.set(libcamera.controls.rpi.CnnKpiInfo, []i32{ @intCast(i32, info.dnnRuntime), @intCast(i32, info.dspRuntime) });
        }

        self.metadataReady.emit(self.libcameraMetadata);
    }

    fn applyFrameDurations(self: *IpaBase, minFrameDuration: std.time.Duration, maxFrameDuration: std.time.Duration) void {
        self.minFrameDuration = std.math.clamp(minFrameDuration != 0 ? minFrameDuration : defaultMinFrameDuration, self.mode.minFrameDuration, self.mode.maxFrameDuration);
        self.maxFrameDuration = std.math.clamp(maxFrameDuration != 0 ? maxFrameDuration : defaultMaxFrameDuration, self.mode.minFrameDuration, self.mode.maxFrameDuration);
        self.maxFrameDuration = std.math.max(self.maxFrameDuration, self.minFrameDuration);

        self.libcameraMetadata.set(libcamera.controls.FrameDurationLimits, []i64{ @intCast(i64, self.minFrameDuration.get(std.time.microsecond)), @intCast(i64, self.maxFrameDuration.get(std.time.microsecond)) });

        var maxExposureTime = std.time.Duration.max();
        const blanking = self.helper.getBlanking(&maxExposureTime, self.minFrameDuration, self.maxFrameDuration);

        const agc = self.controller.getAlgorithm("agc").? as *RPiController.AgcAlgorithm;
        agc.setMaxExposureTime(maxExposureTime);

        const sync = self.controller.getAlgorithm("sync").? as *RPiController.SyncAlgorithm;
        if (sync) |s| {
            const duration = (self.mode.height + blanking.vblank) * ((self.mode.width + blanking.hblank) * std.time.second / self.mode.pixelRate);
            s.setFrameDuration(duration);
        }
    }

    fn applyAGC(self: *IpaBase, agcStatus: *RPiController.AgcStatus, ctrls: *libcamera.ControlList, frameDurationOffset: std.time.Duration) void {
        const minGainCode = self.helper.gainCode(self.mode.minAnalogueGain);
        const maxGainCode = self.helper.gainCode(self.mode.maxAnalogueGain);
        var gainCode = self.helper.gainCode(agcStatus.analogueGain);

        gainCode = std.math.clamp(gainCode, minGainCode, maxGainCode);

        var exposure = agcStatus.exposureTime;
        const blanking = self.helper.getBlanking(&exposure, self.minFrameDuration - frameDurationOffset, self.maxFrameDuration - frameDurationOffset);
        const exposureLines = self.helper.exposureLines(exposure, self.helper.hblankToLineLength(blanking.hblank));

        ctrls.set(libcamera.V4L2_CID_VBLANK, blanking.vblank);
        ctrls.set(libcamera.V4L2_CID_EXPOSURE, exposureLines);
        ctrls.set(libcamera.V4L2_CID_ANALOGUE_GAIN, gainCode);

        if (self.mode.minLineLength != self.mode.maxLineLength) {
            ctrls.set(libcamera.V4L2_CID_HBLANK, blanking.hblank);
        }

        self.frameLengths.popFront();
        self.frameLengths.pushBack(self.helper.exposure(self.mode.height + blanking.vblank, self.helper.hblankToLineLength(blanking.hblank)));
    }
};

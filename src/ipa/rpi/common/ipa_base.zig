const std = @import("std");
const log = @import("log");
const span = @import("span");
const control_ids = @import("control_ids");
const property_ids = @import("property_ids");

const af_algorithm = @import("af_algorithm");
const af_status = @import("af_status");
const agc_algorithm = @import("agc_algorithm");
const awb_algorithm = @import("awb_algorithm");
const awb_status = @import("awb_status");
const black_level_status = @import("black_level_status");
const ccm_algorithm = @import("ccm_algorithm");
const ccm_status = @import("ccm_status");
const contrast_algorithm = @import("contrast_algorithm");
const denoise_algorithm = @import("denoise_algorithm");
const hdr_algorithm = @import("hdr_algorithm");
const lux_status = @import("lux_status");
const sharpen_algorithm = @import("sharpen_algorithm");
const statistics = @import("statistics");
const sync_algorithm = @import("sync_algorithm");
const sync_status = @import("sync_status");

const FrameLengthsQueueSize = 10;
const defaultAnalogueGain = 1.0;
const defaultExposureTime = 20.0ms;
const defaultMinFrameDuration = 1.0s / 30.0;
const defaultMaxFrameDuration = 250.0s;
const controllerMinFrameDuration = 1.0s / 30.0;

const ipaControls = ControlInfoMap{
    .Map = {
        { &control_ids.AeEnable, ControlInfo(false, true) },
        { &control_ids.ExposureTime, ControlInfo(1, 66666, @intCast(i32, defaultExposureTime.get(@tagType(defaultExposureTime)))) },
        { &control_ids.AnalogueGain, ControlInfo(1.0f, 16.0f, 1.0f) },
        { &control_ids.AeMeteringMode, ControlInfo(control_ids.AeMeteringModeValues) },
        { &control_ids.AeConstraintMode, ControlInfo(control_ids.AeConstraintModeValues) },
        { &control_ids.AeExposureMode, ControlInfo(control_ids.AeExposureModeValues) },
        { &control_ids.ExposureValue, ControlInfo(-8.0f, 8.0f, 0.0f) },
        { &control_ids.AeFlickerMode, ControlInfo(@intCast(i32, control_ids.FlickerOff), @intCast(i32, control_ids.FlickerManual), @intCast(i32, control_ids.FlickerOff)) },
        { &control_ids.AeFlickerPeriod, ControlInfo(100, 1000000) },
        { &control_ids.Brightness, ControlInfo(-1.0f, 1.0f, 0.0f) },
        { &control_ids.Contrast, ControlInfo(0.0f, 32.0f, 1.0f) },
        { &control_ids.HdrMode, ControlInfo(control_ids.HdrModeValues) },
        { &control_ids.Sharpness, ControlInfo(0.0f, 16.0f, 1.0f) },
        { &control_ids.ScalerCrop, ControlInfo(Rectangle{}, Rectangle(65535, 65535, 65535, 65535), Rectangle{}) },
        { &control_ids.FrameDurationLimits, ControlInfo(INT64_C(33333), INT64_C(120000), @intCast(i64, defaultMinFrameDuration.get(@tagType(defaultMinFrameDuration)))) },
        { &control_ids.rpi.SyncMode, ControlInfo(control_ids.rpi.SyncModeValues) },
        { &control_ids.rpi.SyncFrames, ControlInfo(1, 1000000, 100) },
        { &control_ids.draft.NoiseReductionMode, ControlInfo(control_ids.draft.NoiseReductionModeValues) },
        { &control_ids.rpi.StatsOutputEnable, ControlInfo(false, true, false) },
        { &control_ids.rpi.CnnEnableInputTensor, ControlInfo(false, true, false) },
    },
};

const ipaColourControls = ControlInfoMap{
    .Map = {
        { &control_ids.AwbEnable, ControlInfo(false, true) },
        { &control_ids.AwbMode, ControlInfo(control_ids.AwbModeValues) },
        { &control_ids.ColourGains, ControlInfo(0.0f, 32.0f) },
        { &control_ids.ColourTemperature, ControlInfo(100, 100000) },
        { &control_ids.Saturation, ControlInfo(0.0f, 32.0f, 1.0f) },
    },
};

const ipaAfControls = ControlInfoMap{
    .Map = {
        { &control_ids.AfMode, ControlInfo(control_ids.AfModeValues) },
        { &control_ids.AfRange, ControlInfo(control_ids.AfRangeValues) },
        { &control_ids.AfSpeed, ControlInfo(control_ids.AfSpeedValues) },
        { &control_ids.AfMetering, ControlInfo(control_ids.AfMeteringValues) },
        { &control_ids.AfWindows, ControlInfo(Rectangle{}, Rectangle(65535, 65535, 65535, 65535), Rectangle{}) },
        { &control_ids.AfTrigger, ControlInfo(control_ids.AfTriggerValues) },
        { &control_ids.AfPause, ControlInfo(control_ids.AfPauseValues) },
        { &control_ids.LensPosition, ControlInfo(0.0f, 32.0f, 1.0f) },
    },
};

const platformControls = std.StringHashMap(ControlInfoMap{
    .Map = {
        { "pisp", {
            { &control_ids.rpi.ScalerCrops, ControlInfo(Rectangle{}, Rectangle(65535, 65535, 65535, 65535), Rectangle{}) }
        } },
    },
});

const IPARPI = log.Category("IPARPI");

const IpaBase = struct {
    controller: Controller,
    frameLengths: [FrameLengthsQueueSize]Duration,
    statsMetadataOutput: bool,
    stitchSwapBuffers: bool,
    frameCount: u64,
    mistrustCount: u32,
    lastRunTimestamp: u64,
    firstStart: bool,
    flickerState: struct {
        mode: i32,
        manualPeriod: Duration,
    },
    cnnEnableInputTensor: bool,

    pub fn init(self: *IpaBase, settings: IPASettings, params: InitParams, result: *InitResult) i32 {
        self.helper = std.heap.CAllocator.create(RPiController.CamHelper, settings.sensorModel);
        if (self.helper == null) {
            log.error(IPARPI, "Could not create camera helper for {}", settings.sensorModel);
            return -EINVAL;
        }

        result.sensorConfig.sensorMetadata = self.helper.sensorEmbeddedDataPresent();

        const ret = self.controller.read(settings.configurationFile);
        if (ret != 0) {
            log.error(IPARPI, "Failed to load tuning data file {}", settings.configurationFile);
            return ret;
        }

        self.lensPresent = params.lensPresent;

        self.controller.initialise();
        self.helper.setHwConfig(self.controller.getHardwareConfig());

        var ctrlMap = ipaControls;
        if (self.lensPresent) {
            ctrlMap.merge(ipaAfControls);
        }

        const platformCtrlsIt = platformControls.get(self.controller.getTarget());
        if (platformCtrlsIt != null) {
            ctrlMap.merge(platformCtrlsIt);
        }

        self.monoSensor = params.sensorInfo.cfaPattern == property_ids.draft.ColorFilterArrangementEnum.MONO;
        if (!self.monoSensor) {
            ctrlMap.merge(ipaColourControls);
        }

        result.controlInfo = ControlInfoMap(ctrlMap, control_ids.controls);

        return self.platformInit(params, result);
    }

    pub fn configure(self: *IpaBase, sensorInfo: IPACameraSensorInfo, params: ConfigParams, result: *ConfigResult) i32 {
        self.sensorCtrls = params.sensorControls;

        if (!self.validateSensorControls()) {
            log.error(IPARPI, "Sensor control validation failed.");
            return -1;
        }

        if (self.lensPresent) {
            self.lensCtrls = params.lensControls;
            if (!self.validateLensControls()) {
                log.warning(IPARPI, "Lens validation failed, no lens control will be available.");
                self.lensPresent = false;
            }
        }

        self.libcameraMetadata = ControlList(control_ids.controls);

        self.setMode(sensorInfo);

        self.mode.transform = @intCast(libcamera.Transform, params.transform);

        self.helper.setCameraMode(self.mode);

        var ctrls = ControlList(self.sensorCtrls);

        result.modeSensitivity = self.mode.sensitivity;

        if (self.firstStart) {
            self.applyFrameDurations(defaultMinFrameDuration, defaultMaxFrameDuration);

            var agcStatus = AgcStatus{
                .exposureTime = defaultExposureTime,
                .analogueGain = defaultAnalogueGain,
            };
            self.applyAGC(&agcStatus, &ctrls);

            if (self.lensPresent) {
                const af = @field(self.controller.getAlgorithm("af"), "af");
                if (af != null) {
                    const defaultPos = ipaAfControls.at(&control_ids.LensPosition).def().get(f32);
                    var lensCtrl = ControlList(self.lensCtrls);
                    var hwpos: i32 = 0;
                    af.setLensPosition(defaultPos, &hwpos);
                    lensCtrl.set(V4L2_CID_FOCUS_ABSOLUTE, hwpos);
                    result.lensControls = lensCtrl;
                }
            }
        }

        result.sensorControls = ctrls;

        var ctrlMap = ipaControls;
        ctrlMap[&control_ids.FrameDurationLimits] = ControlInfo(@intCast(i64, self.mode.minFrameDuration.get(@tagType(self.mode.minFrameDuration))), @intCast(i64, self.mode.maxFrameDuration.get(@tagType(self.mode.maxFrameDuration))), @intCast(i64, defaultMinFrameDuration.get(@tagType(defaultMinFrameDuration))));

        ctrlMap[&control_ids.AnalogueGain] = ControlInfo(@intCast(f32, self.mode.minAnalogueGain), @intCast(f32, self.mode.maxAnalogueGain), @intCast(f32, defaultAnalogueGain));

        ctrlMap[&control_ids.ExposureTime] = ControlInfo(@intCast(i32, self.mode.minExposureTime.get(@tagType(self.mode.minExposureTime))), @intCast(i32, self.mode.maxExposureTime.get(@tagType(self.mode.maxExposureTime))), @intCast(i32, defaultExposureTime.get(@tagType(defaultExposureTime))));

        if (!self.monoSensor) {
            ctrlMap.merge(ipaColourControls);
        }

        if (self.lensPresent) {
            ctrlMap.merge(ipaAfControls);
        }

        result.controlInfo = ControlInfoMap(ctrlMap, control_ids.controls);

        return self.platformConfigure(params, result);
    }

    pub fn start(self: *IpaBase, controls: ControlList, result: *StartResult) void {
        var metadata = RPiController.Metadata{};

        if (!controls.empty()) {
            self.applyControls(controls);
        }

        self.controller.switchMode(self.mode, &metadata);

        self.lastTimeout = 0s;
        self.frameLengths.clear();
        self.frameLengths.resize(FrameLengthsQueueSize, 0s);

        var agcStatus = AgcStatus{
            .exposureTime = 0.0s,
            .analogueGain = 0.0,
        };

        metadata.get("agc.status", &agcStatus);
        if (agcStatus.exposureTime != 0.0s && agcStatus.analogueGain != 0.0) {
            var ctrls = ControlList(self.sensorCtrls);
            self.applyAGC(&agcStatus, &ctrls);
            result.controls = ctrls;
            self.setCameraTimeoutValue();
        }
        self.hdrStatus = agcStatus.hdr;

        self.frameCount = 0;
        if (self.firstStart) {
            self.dropFrameCount = self.helper.hideFramesStartup();
            self.mistrustCount = self.helper.mistrustFramesStartup();

            var agcConvergenceFrames: u32 = 0;
            const agc = @field(self.controller.getAlgorithm("agc"), "agc");
            if (agc != null) {
                agcConvergenceFrames = agc.getConvergenceFrames();
                if (agcConvergenceFrames != 0) {
                    agcConvergenceFrames += self.mistrustCount;
                }
            }

            var awbConvergenceFrames: u32 = 0;
            const awb = @field(self.controller.getAlgorithm("awb"), "awb");
            if (awb != null) {
                awbConvergenceFrames = awb.getConvergenceFrames();
                if (awbConvergenceFrames != 0) {
                    awbConvergenceFrames += self.mistrustCount;
                }
            }

            self.dropFrameCount = std.math.max(std.math.max(self.dropFrameCount, agcConvergenceFrames), awbConvergenceFrames);
            log.debug(IPARPI, "Drop {} frames on startup", self.dropFrameCount);
        } else {
            self.dropFrameCount = self.helper.hideFramesModeSwitch();
            self.mistrustCount = self.helper.mistrustFramesModeSwitch();
        }

        result.dropFrameCount = self.dropFrameCount;

        self.firstStart = false;
        self.lastRunTimestamp = 0;

        self.platformStart(controls, result);
    }

    pub fn mapBuffers(self: *IpaBase, buffers: []const IPABuffer) void {
        for (buffers) |buffer| {
            const fb = FrameBuffer(buffer.planes);
            self.buffers.put(buffer.id, MappedFrameBuffer(&fb, MappedFrameBuffer.MapFlag.ReadWrite));
        }
    }

    pub fn unmapBuffers(self: *IpaBase, ids: []const u32) void {
        for (ids) |id| {
            const it = self.buffers.get(id);
            if (it != null) {
                self.buffers.remove(id);
            }
        }
    }

    pub fn prepareIsp(self: *IpaBase, params: PrepareParams) void {
        self.applyControls(params.requestControls);

        const frameTimestamp = params.sensorControls.get(control_ids.SensorTimestamp).value_or(0);
        const ipaContext = params.ipaContext % self.rpiMetadata.len;
        var rpiMetadata = &self.rpiMetadata[ipaContext];
        var embeddedBuffer: span.Span(u8) = span.Span(u8){};

        rpiMetadata.clear();
        self.fillDeviceStatus(params.sensorControls, ipaContext);
        self.fillSyncParams(params, ipaContext);

        if (params.buffers.embedded != 0) {
            const it = self.buffers.get(params.buffers.embedded);
            assert(it != null);
            embeddedBuffer = it.planes[0];
        }

        var agcStatus = AgcStatus{};
        var hdrChange = false;
        var delayedMetadata = &self.rpiMetadata[params.delayContext];
        if (!delayedMetadata.get("agc.status", &agcStatus)) {
            rpiMetadata.set("agc.delayed_status", agcStatus);
            hdrChange = agcStatus.hdr.mode != self.hdrStatus.mode;
            self.hdrStatus = agcStatus.hdr;
        }

        self.helper.prepare(embeddedBuffer, rpiMetadata);

        const delta = (frameTimestamp - self.lastRunTimestamp) * 1.0ns;
        if (self.lastRunTimestamp != 0 && self.frameCount > self.dropFrameCount && delta < controllerMinFrameDuration * 0.9 && !hdrChange) {
            var lastMetadata = &self.rpiMetadata[(ipaContext != 0 ? ipaContext : self.rpiMetadata.len) - 1];
            rpiMetadata.mergeCopy(lastMetadata);
            self.processPending = false;
        } else {
            self.processPending = true;
            self.lastRunTimestamp = frameTimestamp;
        }

        if (self.controller.getHardwareConfig().statsInline) {
            self.processStats(params);
        }

        if (self.processPending) {
            self.controller.prepare(rpiMetadata);
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

        if (self.processPending && self.frameCount >= self.mistrustCount) {
            var rpiMetadata = &self.rpiMetadata[ipaContext];

            const it = self.buffers.get(params.buffers.stats);
            if (it == null) {
                log.error(IPARPI, "Could not find stats buffer!");
                return;
            }

            const statistics = self.platformProcessStats(it.planes[0]);

            rpiMetadata.set("focus.status", statistics.focusRegions);

            self.helper.process(statistics, rpiMetadata);
            self.controller.process(statistics, rpiMetadata);

            var offset = Duration(0s);
            var syncStatus = SyncStatus{};
            if (rpiMetadata.get("sync.status", &syncStatus) == 0) {
                if (self.minFrameDuration != self.maxFrameDuration) {
                    log.error(IPARPI, "Sync algorithm enabled with variable framerate. {} {}", self.minFrameDuration, self.maxFrameDuration);
                }
                offset = syncStatus.frameDurationOffset;

                self.libcameraMetadata.set(control_ids.rpi.SyncReady, syncStatus.ready);
                if (syncStatus.timerKnown) {
                    self.libcameraMetadata.set(control_ids.rpi.SyncTimer, syncStatus.timerValue);
                }
            }

            var agcStatus = AgcStatus{};
            if (rpiMetadata.get("agc.status", &agcStatus) == 0) {
                var ctrls = ControlList(self.sensorCtrls);
                self.applyAGC(&agcStatus, &ctrls, offset);
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

        self.mode.binX = std.math.min(2, @intCast(int, self.mode.scaleX));
        self.mode.binY = std.math.min(2, @intCast(int, self.mode.scaleY));

        self.mode.noiseFactor = std.math.sqrt(self.mode.binX * self.mode.binY);

        self.mode.minLineLength = sensorInfo.minLineLength * (1.0s / sensorInfo.pixelRate);
        self.mode.maxLineLength = sensorInfo.maxLineLength * (1.0s / sensorInfo.pixelRate);

        const minPixelTime = self.controller.getHardwareConfig().minPixelProcessingTime;
        const pixelTime = self.mode.minLineLength / self.mode.width;
        if (minPixelTime != 0 && pixelTime < minPixelTime) {
            const adjustedLineLength = minPixelTime * self.mode.width;
            if (adjustedLineLength <= self.mode.maxLineLength) {
                log.info(IPARPI, "Adjusting mode minimum line length from {} to {} because of ISP constraints.", self.mode.minLineLength, adjustedLineLength);
                self.mode.minLineLength = adjustedLineLength;
            } else {
                log.error(IPARPI, "Sensor minimum line length of {} ({}) is below the minimum allowable ISP limit of {} ({})", pixelTime * self.mode.width, 1us / pixelTime, adjustedLineLength, 1us / minPixelTime);
                log.error(IPARPI, "THIS WILL CAUSE IMAGE CORRUPTION!!! Please update the camera sensor driver to allow more horizontal blanking control.");
            }
        }

        self.mode.minFrameLength = sensorInfo.minFrameLength;
        self.mode.maxFrameLength = sensorInfo.maxFrameLength;

        self.mode.minFrameDuration = self.mode.minFrameLength * self.mode.minLineLength;
        self.mode.maxFrameDuration = self.mode.maxFrameLength * self.mode.maxLineLength;

        self.mode.sensitivity = self.helper.getModeSensitivity(self.mode);

        const gainCtrl = self.sensorCtrls.at(V4L2_CID_ANALOGUE_GAIN);
        const exposureTimeCtrl = self.sensorCtrls.at(V4L2_CID_EXPOSURE);

        self.mode.minAnalogueGain = self.helper.gain(gainCtrl.min().get(i32));
        self.mode.maxAnalogueGain = self.helper.gain(gainCtrl.max().get(i32));

        self.helper.setCameraMode(self.mode);

        self.mode.minExposureTime = self.helper.exposure(exposureTimeCtrl.min().get(i32), self.mode.minLineLength);
        self.mode.maxExposureTime = Duration.max();
        self.helper.getBlanking(self.mode.maxExposureTime, self.mode.minFrameDuration, self.mode.maxFrameDuration);
    }

    fn setCameraTimeoutValue(self: *IpaBase) void {
        const max = std.math.max(self.frameLengths);

        if (max != self.lastTimeout) {
            self.setCameraTimeout.emit(max.get(@tagType(max)));
            self.lastTimeout = max;
        }
    }

    fn validateSensorControls(self: *IpaBase) bool {
        const ctrls = []u32{
            V4L2_CID_ANALOGUE_GAIN,
            V4L2_CID_EXPOSURE,
            V4L2_CID_VBLANK,
            V4L2_CID_HBLANK,
        };

        for (ctrls) |c| {
            if (self.sensorCtrls.get(c) == null) {
                log.error(IPARPI, "Unable to find sensor control {}", c);
                return false;
            }
        }

        return true;
    }

    fn validateLensControls(self: *IpaBase) bool {
        if (self.lensCtrls.get(V4L2_CID_FOCUS_ABSOLUTE) == null) {
            log.error(IPARPI, "Unable to find Lens control V4L2_CID_FOCUS_ABSOLUTE");
            return false;
        }

        return true;
    }

    fn applyControls(self: *IpaBase, controls: ControlList) void {
        self.libcameraMetadata.clear();

        if (controls.contains(control_ids.AF_MODE)) {
            const af = @field(self.controller.getAlgorithm("af"), "af");
            if (af == null) {
                log.warning(IPARPI, "Could not set AF_MODE - no AF algorithm");
            }

            const idx = controls.get(control_ids.AF_MODE).get(i32);
            const mode = AfModeTable.get(idx);
            if (mode == null) {
                log.error(IPARPI, "AF mode {} not recognised", idx);
            } else if (af != null) {
                af.setMode(mode);
            }
        }

        for (controls) |ctrl| {
            log.debug(IPARPI, "Request ctrl: {} = {}", control_ids.controls.get(ctrl.first).name(), ctrl.second.toString());

            switch (ctrl.first) {
                control_ids.AE_ENABLE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AE_ENABLE - no AGC algorithm");
                        break;
                    }

                    if (ctrl.second.get(bool) == false) {
                        agc.disableAuto();
                    } else {
                        agc.enableAuto();
                    }

                    self.libcameraMetadata.set(control_ids.AeEnable, ctrl.second.get(bool));
                },
                control_ids.EXPOSURE_TIME => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set EXPOSURE_TIME - no AGC algorithm");
                        break;
                    }

                    agc.setFixedExposureTime(0, ctrl.second.get(i32) * 1.0us);

                    self.libcameraMetadata.set(control_ids.ExposureTime, ctrl.second.get(i32));
                },
                control_ids.ANALOGUE_GAIN => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set ANALOGUE_GAIN - no AGC algorithm");
                        break;
                    }

                    agc.setFixedAnalogueGain(0, ctrl.second.get(f32));

                    self.libcameraMetadata.set(control_ids.AnalogueGain, ctrl.second.get(f32));
                },
                control_ids.AE_METERING_MODE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AE_METERING_MODE - no AGC algorithm");
                        break;
                    }

                    const idx = ctrl.second.get(i32);
                    if (MeteringModeTable.get(idx) != null) {
                        agc.setMeteringMode(MeteringModeTable.get(idx));
                        self.libcameraMetadata.set(control_ids.AeMeteringMode, idx);
                    } else {
                        log.error(IPARPI, "Metering mode {} not recognised", idx);
                    }
                },
                control_ids.AE_CONSTRAINT_MODE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AE_CONSTRAINT_MODE - no AGC algorithm");
                        break;
                    }

                    const idx = ctrl.second.get(i32);
                    if (ConstraintModeTable.get(idx) != null) {
                        agc.setConstraintMode(ConstraintModeTable.get(idx));
                        self.libcameraMetadata.set(control_ids.AeConstraintMode, idx);
                    } else {
                        log.error(IPARPI, "Constraint mode {} not recognised", idx);
                    }
                },
                control_ids.AE_EXPOSURE_MODE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AE_EXPOSURE_MODE - no AGC algorithm");
                        break;
                    }

                    const idx = ctrl.second.get(i32);
                    if (ExposureModeTable.get(idx) != null) {
                        agc.setExposureMode(ExposureModeTable.get(idx));
                        self.libcameraMetadata.set(control_ids.AeExposureMode, idx);
                    } else {
                        log.error(IPARPI, "Exposure mode {} not recognised", idx);
                    }
                },
                control_ids.EXPOSURE_VALUE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set EXPOSURE_VALUE - no AGC algorithm");
                        break;
                    }

                    const ev = std.math.pow(2.0, ctrl.second.get(f32));
                    agc.setEv(0, ev);
                    self.libcameraMetadata.set(control_ids.ExposureValue, ctrl.second.get(f32));
                },
                control_ids.AE_FLICKER_MODE => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AeFlickerMode - no AGC algorithm");
                        break;
                    }

                    const mode = ctrl.second.get(i32);
                    var modeValid = true;

                    switch (mode) {
                        control_ids.FlickerOff => {
                            agc.setFlickerPeriod(0us);
                        },
                        control_ids.FlickerManual => {
                            agc.setFlickerPeriod(self.flickerState.manualPeriod);
                        },
                        else => {
                            log.error(IPARPI, "Flicker mode {} is not supported", mode);
                            modeValid = false;
                        },
                    }

                    if (modeValid) {
                        self.flickerState.mode = mode;
                    }
                },
                control_ids.AE_FLICKER_PERIOD => {
                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "Could not set AeFlickerPeriod - no AGC algorithm");
                        break;
                    }

                    const manualPeriod = ctrl.second.get(i32);
                    self.flickerState.manualPeriod = manualPeriod * 1.0us;

                    if (self.flickerState.mode == control_ids.FlickerManual) {
                        agc.setFlickerPeriod(self.flickerState.manualPeriod);
                    }
                },
                control_ids.AWB_ENABLE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const awb = @field(self.controller.getAlgorithm("awb"), "awb");
                    if (awb == null) {
                        log.warning(IPARPI, "Could not set AWB_ENABLE - no AWB algorithm");
                        break;
                    }

                    if (ctrl.second.get(bool) == false) {
                        awb.disableAuto();
                    } else {
                        awb.enableAuto();
                    }

                    self.libcameraMetadata.set(control_ids.AwbEnable, ctrl.second.get(bool));
                },
                control_ids.AWB_MODE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const awb = @field(self.controller.getAlgorithm("awb"), "awb");
                    if (awb == null) {
                        log.warning(IPARPI, "Could not set AWB_MODE - no AWB algorithm");
                        break;
                    }

                    const idx = ctrl.second.get(i32);
                    if (AwbModeTable.get(idx) != null) {
                        awb.setMode(AwbModeTable.get(idx));
                        self.libcameraMetadata.set(control_ids.AwbMode, idx);
                    } else {
                        log.error(IPARPI, "AWB mode {} not recognised", idx);
                    }
                },
                control_ids.COLOUR_GAINS => {
                    if (self.monoSensor) {
                        break;
                    }

                    const gains = ctrl.second.get(span.Span(f32));
                    const awb = @field(self.controller.getAlgorithm("awb"), "awb");
                    if (awb == null) {
                        log.warning(IPARPI, "Could not set COLOUR_GAINS - no AWB algorithm");
                        break;
                    }

                    awb.setManualGains(gains[0], gains[1]);
                    if (gains[0] != 0.0f && gains[1] != 0.0f) {
                        self.libcameraMetadata.set(control_ids.ColourGains, gains);
                    }
                },
                control_ids.COLOUR_TEMPERATURE => {
                    if (self.monoSensor) {
                        break;
                    }

                    const temperatureK = ctrl.second.get(i32);
                    const awb = @field(self.controller.getAlgorithm("awb"), "awb");
                    if (awb == null) {
                        log.warning(IPARPI, "Could not set COLOUR_TEMPERATURE - no AWB algorithm");
                        break;
                    }

                    awb.setColourTemperature(temperatureK);
                },
                control_ids.BRIGHTNESS => {
                    const contrast = @field(self.controller.getAlgorithm("contrast"), "contrast");
                    if (contrast == null) {
                        log.warning(IPARPI, "Could not set BRIGHTNESS - no contrast algorithm");
                        break;
                    }

                    contrast.setBrightness(ctrl.second.get(f32) * 65536);
                    self.libcameraMetadata.set(control_ids.Brightness, ctrl.second.get(f32));
                },
                control_ids.CONTRAST => {
                    const contrast = @field(self.controller.getAlgorithm("contrast"), "contrast");
                    if (contrast == null) {
                        log.warning(IPARPI, "Could not set CONTRAST - no contrast algorithm");
                        break;
                    }

                    contrast.setContrast(ctrl.second.get(f32));
                    self.libcameraMetadata.set(control_ids.Contrast, ctrl.second.get(f32));
                },
                control_ids.SATURATION => {
                    if (self.monoSensor) {
                        break;
                    }

                    const ccm = @field(self.controller.getAlgorithm("ccm"), "ccm");
                    if (ccm == null) {
                        log.warning(IPARPI, "Could not set SATURATION - no ccm algorithm");
                        break;
                    }

                    ccm.setSaturation(ctrl.second.get(f32));
                    self.libcameraMetadata.set(control_ids.Saturation, ctrl.second.get(f32));
                },
                control_ids.SHARPNESS => {
                    const sharpen = @field(self.controller.getAlgorithm("sharpen"), "sharpen");
                    if (sharpen == null) {
                        log.warning(IPARPI, "Could not set SHARPNESS - no sharpen algorithm");
                        break;
                    }

                    sharpen.setStrength(ctrl.second.get(f32));
                    self.libcameraMetadata.set(control_ids.Sharpness, ctrl.second.get(f32));
                },
                control_ids.rpi.SCALER_CROPS,
                control_ids.SCALER_CROP => {
                },
                control_ids.FRAME_DURATION_LIMITS => {
                    const frameDurations = ctrl.second.get(span.Span(i64));
                    self.applyFrameDurations(frameDurations[0] * 1.0us, frameDurations[1] * 1.0us);
                },
                control_ids.draft.NOISE_REDUCTION_MODE => {
                    self.libcameraMetadata.set(control_ids.draft.NoiseReductionMode, ctrl.second.get(i32));
                },
                control_ids.AF_MODE => {
                },
                control_ids.AF_RANGE => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null) {
                        log.warning(IPARPI, "Could not set AF_RANGE - no focus algorithm");
                        break;
                    }

                    const range = AfRangeTable.get(ctrl.second.get(i32));
                    if (range == null) {
                        log.error(IPARPI, "AF range {} not recognised", ctrl.second.get(i32));
                        break;
                    }
                    af.setRange(range);
                },
                control_ids.AF_SPEED => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null) {
                        log.warning(IPARPI, "Could not set AF_SPEED - no focus algorithm");
                        break;
                    }

                    const speed = ctrl.second.get(i32) == control_ids.AfSpeedFast ? af_algorithm.AfSpeedFast : af_algorithm.AfSpeedNormal;
                    af.setSpeed(speed);
                },
                control_ids.AF_METERING => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null) {
                        log.warning(IPARPI, "Could not set AF_METERING - no AF algorithm");
                        break;
                    }
                    af.setMetering(ctrl.second.get(i32) == control_ids.AfMeteringWindows);
                },
                control_ids.AF_WINDOWS => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null) {
                        log.warning(IPARPI, "Could not set AF_WINDOWS - no AF algorithm");
                        break;
                    }
                    af.setWindows(ctrl.second.get(span.Span(Rectangle)));
                },
                control_ids.AF_PAUSE => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null || af.getMode() != af_algorithm.AfModeContinuous) {
                        log.warning(IPARPI, "Could not set AF_PAUSE - no AF algorithm or not Continuous");
                        break;
                    }
                    const pause = AfPauseTable.get(ctrl.second.get(i32));
                    if (pause == null) {
                        log.error(IPARPI, "AF pause {} not recognised", ctrl.second.get(i32));
                        break;
                    }
                    af.pause(pause);
                },
                control_ids.AF_TRIGGER => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af == null || af.getMode() != af_algorithm.AfModeAuto) {
                        log.warning(IPARPI, "Could not set AF_TRIGGER - no AF algorithm or not Auto");
                        break;
                    } else {
                        if (ctrl.second.get(i32) == control_ids.AfTriggerStart) {
                            af.triggerScan();
                        } else {
                            af.cancelScan();
                        }
                    }
                },
                control_ids.LENS_POSITION => {
                    const af = @field(self.controller.getAlgorithm("af"), "af");
                    if (af != null) {
                        var hwpos: i32 = 0;
                        if (af.setLensPosition(ctrl.second.get(f32), &hwpos)) {
                            var lensCtrls = ControlList(self.lensCtrls);
                            lensCtrls.set(V4L2_CID_FOCUS_ABSOLUTE, hwpos);
                            self.setLensControls.emit(lensCtrls);
                        }
                    } else {
                        log.warning(IPARPI, "Could not set LENS_POSITION - no AF algorithm");
                    }
                },
                control_ids.HDR_MODE => {
                    const hdr = @field(self.controller.getAlgorithm("hdr"), "hdr");
                    if (hdr == null) {
                        log.warning(IPARPI, "No HDR algorithm available");
                        break;
                    }

                    const mode = HdrModeTable.get(ctrl.second.get(i32));
                    if (mode == null) {
                        log.warning(IPARPI, "Unrecognised HDR mode");
                        break;
                    }

                    const agc = @field(self.controller.getAlgorithm("agc"), "agc");
                    if (agc == null) {
                        log.warning(IPARPI, "HDR requires an AGC algorithm");
                        break;
                    }

                    if (hdr.setMode(mode) == 0) {
                        agc.setActiveChannels(hdr.getChannels());

                        const contrast = @field(self.controller.getAlgorithm("contrast"), "contrast");
                        if (contrast != null) {
                            if (mode == "Off") {
                                contrast.restoreCe();
                            } else {
                                contrast.enableCe(false);
                            }
                        }

                        const denoise = @field(self.controller.getAlgorithm("denoise"), "denoise");
                        if (denoise != null) {
                            if (mode == "Night") {
                                denoise.setConfig("night");
                            } else if (mode == "SingleExposure") {
                                denoise.setConfig("hdr");
                            } else {
                                denoise.setConfig("normal");
                            }
                        }
                    } else {
                        log.warning(IPARPI, "HDR mode {} not supported", mode);
                    }
                },
                control_ids.rpi.STATS_OUTPUT_ENABLE => {
                    self.statsMetadataOutput = ctrl.second.get(bool);
                },
                control_ids.rpi.CNN_ENABLE_INPUT_TENSOR => {
                    self.cnnEnableInputTensor = ctrl.second.get(bool);
                },
                control_ids.rpi.SYNC_MODE => {
                    const sync = @field(self.controller.getAlgorithm("sync"), "sync");

                    if (sync != null) {
                        const mode = ctrl.second.get(i32);
                        var m = sync_algorithm.Mode.Off;
                        if (mode == control_ids.rpi.SyncModeServer) {
                            m = sync_algorithm.Mode.Server;
                            log.info(IPARPI, "Sync mode set to server");
                        } else if (mode == control_ids.rpi.SyncModeClient) {
                            m = sync_algorithm.Mode.Client;
                            log.info(IPARPI, "Sync mode set to client");
                        }
                        sync.setMode(m);
                    }
                },
                control_ids.rpi.SYNC_FRAMES => {
                    const sync = @field(self.controller.getAlgorithm("sync"), "sync");

                    if (sync != null) {
                        const frames = ctrl.second.get(i32);
                        if (frames > 0) {
                            sync.setReadyFrame(frames);
                        }
                    }
                },
                else => {
                    log.warning(IPARPI, "Ctrl {} is not handled.", control_ids.controls.get(ctrl.first).name());
                },
            }
        }

        self.handleControls(controls);
    }

    fn fillDeviceStatus(self: *IpaBase, sensorControls: ControlList, ipaContext: u32) void {
        var deviceStatus = DeviceStatus{};

        const exposureLines = sensorControls.get(V4L2_CID_EXPOSURE).get(i32);
        const gainCode = sensorControls.get(V4L2_CID_ANALOGUE_GAIN).get(i32);
        const vblank = sensorControls.get(V4L2_CID_VBLANK).get(i32);
        const hblank = sensorControls.get(V4L2_CID_HBLANK).get(i32);

        deviceStatus.lineLength = self.helper.hblankToLineLength(hblank);
        deviceStatus.exposureTime = self.helper.exposure(exposureLines, deviceStatus.lineLength);
        deviceStatus.analogueGain = self.helper.gain(gainCode);
        deviceStatus.frameLength = self.mode.height + vblank;

        const af = @field(self.controller.getAlgorithm("af"), "af");
        if (af != null) {
            deviceStatus.lensPosition = af.getLensPosition();
        }

        log.debug(IPARPI, "Metadata - {}", deviceStatus);

        self.rpiMetadata[ipaContext].set("device.status", deviceStatus);
    }

    fn fillSyncParams(self: *IpaBase, params: PrepareParams, ipaContext: u32) void {
        const sync = @field(self.controller.getAlgorithm("sync"), "sync");
        if (sync == null) {
            return;
        }

        var syncParams = SyncParams{
            .wallClock = params.sensorControls.get(control_ids.FrameWallClock).?,
            .sensorTimestamp = params.sensorControls.get(control_ids.SensorTimestamp).?,
        };
        self.rpiMetadata[ipaContext].set("sync.params", syncParams);
    }

    fn reportMetadata(self: *IpaBase, ipaContext: u32) void {
        var rpiMetadata = &self.rpiMetadata[ipaContext];
        var lock = std.mutex.Lock(rpiMetadata);

        const deviceStatus = rpiMetadata.getLocked(DeviceStatus, "device.status");
        if (deviceStatus != null) {
            self.libcameraMetadata.set(control_ids.ExposureTime, deviceStatus.exposureTime.get(@tagType(deviceStatus.exposureTime)));
            self.libcameraMetadata.set(control_ids.AnalogueGain, deviceStatus.analogueGain);
            self.libcameraMetadata.set(control_ids.FrameDuration, self.helper.exposure(deviceStatus.frameLength, deviceStatus.lineLength).get(@tagType(deviceStatus.exposureTime)));
            if (deviceStatus.sensorTemperature != null) {
                self.libcameraMetadata.set(control_ids.SensorTemperature, deviceStatus.sensorTemperature.?);
            }
            if (deviceStatus.lensPosition != null) {
                self.libcameraMetadata.set(control_ids.LensPosition, deviceStatus.lensPosition.?);
            }
        }

        const agcPrepareStatus = rpiMetadata.getLocked(AgcPrepareStatus, "agc.prepare_status");
        if (agcPrepareStatus != null) {
            self.libcameraMetadata.set(control_ids.AeLocked, agcPrepareStatus.locked);
            self.libcameraMetadata.set(control_ids.DigitalGain, agcPrepareStatus.digitalGain);
        }

        const luxStatus = rpiMetadata.getLocked(LuxStatus, "lux.status");
        if (luxStatus != null) {
            self.libcameraMetadata.set(control_ids.Lux, luxStatus.lux);
        }

        const awbStatus = rpiMetadata.getLocked(AwbStatus, "awb.status");
        if (awbStatus != null) {
            self.libcameraMetadata.set(control_ids.ColourGains, { @intCast(f32, awbStatus.gainR), @intCast(f32, awbStatus.gainB) });
            self.libcameraMetadata.set(control_ids.ColourTemperature, awbStatus.temperatureK);
        }

        const blackLevelStatus = rpiMetadata.getLocked(BlackLevelStatus, "black_level.status");
        if (blackLevelStatus != null) {
            self.libcameraMetadata.set(control_ids.SensorBlackLevels, { @intCast(i32, blackLevelStatus.blackLevelR), @intCast(i32, blackLevelStatus.blackLevelG), @intCast(i32, blackLevelStatus.blackLevelG), @intCast(i32, blackLevelStatus.blackLevelB) });
        }

        const focusStatus = rpiMetadata.getLocked(RPiController.FocusRegions, "focus.status");
        if (focusStatus != null) {
            const size = focusStatus.size();
            const rows = size.height;
            const cols = size.width;

            var sum: u64 = 0;
            var numRegions: u32 = 0;
            for (rows / 3..rows - rows / 3) |r| {
                for (cols / 4..cols - cols / 4) |c| {
                    sum += focusStatus.get({ @intCast(int, c), @intCast(int, r) }).val;
                    numRegions += 1;
                }
            }

            const focusFoM = @intCast(u32, sum / numRegions);
            self.libcameraMetadata.set(control_ids.FocusFoM, focusFoM);
        }

        const ccmStatus = rpiMetadata.getLocked(CcmStatus, "ccm.status");
        if (ccmStatus != null) {
            var m: [9]f32 = undefined;
            for (0..9) |i| {
                m[i] = ccmStatus.matrix[i];
            }
            self.libcameraMetadata.set(control_ids.ColourCorrectionMatrix, m);
        }

        const afStatus = rpiMetadata.getLocked(AfStatus, "af.status");
        if (afStatus != null) {
            var s: i32 = 0;
            var p: i32 = 0;
            switch (afStatus.state) {
                AfState.Scanning => {
                    s = control_ids.AfStateScanning;
                },
                AfState.Focused => {
                    s = control_ids.AfStateFocused;
                },
                AfState.Failed => {
                    s = control_ids.AfStateFailed;
                },
                else => {
                    s = control_ids.AfStateIdle;
                },
            }
            switch (afStatus.pauseState) {
                AfPauseState.Pausing => {
                    p = control_ids.AfPauseStatePausing;
                },
                AfPauseState.Paused => {
                    p = control_ids.AfPauseStatePaused;
                },
                else => {
                    p = control_ids.AfPauseStateRunning;
                },
            }
            self.libcameraMetadata.set(control_ids.AfState, s);
            self.libcameraMetadata.set(control_ids.AfPauseState, p);
        }

        const agcStatus = rpiMetadata.getLocked(AgcStatus, "agc.delayed_status");
        const hdrStatus = agcStatus != null ? agcStatus.hdr : self.hdrStatus;
        if (!hdrStatus.mode.empty() && hdrStatus.mode != "Off") {
            var hdrMode = control_ids.HdrModeOff;
            for (HdrModeTable) |mode, name| {
                if (hdrStatus.mode == name) {
                    hdrMode = mode;
                    break;
                }
            }
            self.libcameraMetadata.set(control_ids.HdrMode, hdrMode);

            if (hdrStatus.channel == "short") {
                self.libcameraMetadata.set(control_ids.HdrChannel, control_ids.HdrChannelShort);
            } else if (hdrStatus.channel == "long") {
                self.libcameraMetadata.set(control_ids.HdrChannel, control_ids.HdrChannelLong);
            } else if (hdrStatus.channel == "medium") {
                self.libcameraMetadata.set(control_ids.HdrChannel, control_ids.HdrChannelMedium);
            } else {
                self.libcameraMetadata.set(control_ids.HdrChannel, control_ids.HdrChannelNone);
            }
        }

        const inputTensor = rpiMetadata.getLocked(std.shared_ptr(u8), "cnn.input_tensor");
        if (self.cnnEnableInputTensor && inputTensor != null) {
            const size = rpiMetadata.getLocked(u32, "cnn.input_tensor_size").?;
            const tensor = span.Span(u8){ .ptr = inputTensor.get(), .len = size };
            self.libcameraMetadata.set(control_ids.rpi.CnnInputTensor, tensor);
            rpiMetadata.eraseLocked("cnn.input_tensor");
        }

        const inputTensorInfo = rpiMetadata.getLocked(RPiController.CnnInputTensorInfo, "cnn.input_tensor_info");
        if (inputTensorInfo != null) {
            const tensorInfo = span.Span(u8){ .ptr = @ptrCast(*const u8, inputTensorInfo), .len = @sizeOf(RPiController.CnnInputTensorInfo) };
            self.libcameraMetadata.set(control_ids.rpi.CnnInputTensorInfo, tensorInfo);
        }

        const outputTensor = rpiMetadata.getLocked(std.shared_ptr(f32), "cnn.output_tensor");
        if (outputTensor != null) {
            const size = rpiMetadata.getLocked(u32, "cnn.output_tensor_size").?;
            const tensor = span.Span(f32){ .ptr = @ptrCast(*const f32, outputTensor.get()), .len = size };
            self.libcameraMetadata.set(control_ids.rpi.CnnOutputTensor, tensor);
            rpiMetadata.eraseLocked("cnn.output_tensor");
        }

        const outputTensorInfo = rpiMetadata.getLocked(RPiController.CnnOutputTensorInfo, "cnn.output_tensor_info");
        if (outputTensorInfo != null) {
            const tensorInfo = span.Span(u8){ .ptr = @ptrCast(*const u8, outputTensorInfo), .len = @sizeOf(RPiController.CnnOutputTensorInfo) };
            self.libcameraMetadata.set(control_ids.rpi.CnnOutputTensorInfo, tensorInfo);
        }

        const kpiInfo = rpiMetadata.getLocked(RPiController.CnnKpiInfo, "cnn.kpi_info");
        if (kpiInfo != null) {
            self.libcameraMetadata.set(control_ids.rpi.CnnKpiInfo, { @intCast(i32, kpiInfo.dnnRuntime), @intCast(i32, kpiInfo.dspRuntime) });
        }

        self.metadataReady.emit(self.libcameraMetadata);
    }

    fn applyFrameDurations(self: *IpaBase, minFrameDuration: Duration, maxFrameDuration: Duration) void {
        self.minFrameDuration = minFrameDuration != 0 ? minFrameDuration : defaultMinFrameDuration;
        self.maxFrameDuration = maxFrameDuration != 0 ? maxFrameDuration : defaultMaxFrameDuration;
        self.minFrameDuration = std.math.clamp(self.minFrameDuration, self.mode.minFrameDuration, self.mode.maxFrameDuration);
        self.maxFrameDuration = std.math.clamp(self.maxFrameDuration, self.mode.minFrameDuration, self.mode.maxFrameDuration);
        self.maxFrameDuration = std.math.max(self.maxFrameDuration, self.minFrameDuration);

        self.libcameraMetadata.set(control_ids.FrameDurationLimits, { @intCast(i64, self.minFrameDuration.get(@tagType(self.minFrameDuration))), @intCast(i64, self.maxFrameDuration.get(@tagType(self.maxFrameDuration))) });

        var maxExposureTime = Duration.max();
        const blanking = self.helper.getBlanking(&maxExposureTime, self.minFrameDuration, self.maxFrameDuration);

        const agc = @field(self.controller.getAlgorithm("agc"), "agc");
        agc.setMaxExposureTime(maxExposureTime);

        const sync = @field(self.controller.getAlgorithm("sync"), "sync");
        if (sync != null) {
            const duration = (self.mode.height + blanking.vblank) * ((self.mode.width + blanking.hblank) * 1.0s / self.mode.pixelRate);
            log.debug(IPARPI, "setting sync frame duration to {}", duration);
            sync.setFrameDuration(duration);
        }
    }

    fn applyAGC(self: *IpaBase, agcStatus: *const AgcStatus, ctrls: *ControlList, frameDurationOffset: Duration) void {
        const minGainCode = self.helper.gainCode(self.mode.minAnalogueGain);
        const maxGainCode = self.helper.gainCode(self.mode.maxAnalogueGain);
        var gainCode = self.helper.gainCode(agcStatus.analogueGain);

        gainCode = std.math.clamp(gainCode, minGainCode, maxGainCode);

        var exposure = agcStatus.exposureTime;
        const blanking = self.helper.getBlanking(&exposure, self.minFrameDuration - frameDurationOffset, self.maxFrameDuration - frameDurationOffset);
        const exposureLines = self.helper.exposureLines(exposure, self.helper.hblankToLineLength(blanking.hblank));

        log.debug(IPARPI, "Applying AGC Exposure: {} (Exposure lines: {}, AGC requested {}) Gain: {} (Gain Code: {})", exposure, exposureLines, agcStatus.exposureTime, agcStatus.analogueGain, gainCode);

        ctrls.set(V4L2_CID_VBLANK, @intCast(i32, blanking.vblank));
        ctrls.set(V4L2_CID_EXPOSURE, exposureLines);
        ctrls.set(V4L2_CID_ANALOGUE_GAIN, gainCode);

        if (self.mode.minLineLength != self.mode.maxLineLength) {
            ctrls.set(V4L2_CID_HBLANK, @intCast(i32, blanking.hblank));
        }

        self.frameLengths.popFront();
        self.frameLengths.pushBack(self.helper.exposure(self.mode.height + blanking.vblank, self.helper.hblankToLineLength(blanking.hblank)));
    }
};

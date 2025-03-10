const std = @import("std");
const log = @import("log");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");

const NAME = "rpi.af";

const MaxWindows = 10;

const Af = struct {
    controller: ?*Controller,
    cfg: CfgParams,
    range: AfRange,
    speed: AfSpeed,
    mode: AfMode,
    pauseFlag: bool,
    statsRegion: libcamera.Rectangle,
    windows: []libcamera.Rectangle,
    useWindows: bool,
    phaseWeights: RegionWeights,
    contrastWeights: RegionWeights,
    scanState: ScanState,
    initted: bool,
    ftarget: f64,
    fsmooth: f64,
    prevContrast: f64,
    skipCount: u32,
    stepCount: u32,
    dropCount: u32,
    scanMaxContrast: f64,
    scanMinContrast: f64,
    scanData: []ScanRecord,
    reportState: AfState,

    pub fn init(controller: ?*Controller) Af {
        return Af{
            .controller = controller,
            .cfg = CfgParams.init(),
            .range = AfRangeNormal,
            .speed = AfSpeedNormal,
            .mode = AfModeManual,
            .pauseFlag = false,
            .statsRegion = libcamera.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .windows = &[_]libcamera.Rectangle{},
            .useWindows = false,
            .phaseWeights = RegionWeights.init(),
            .contrastWeights = RegionWeights.init(),
            .scanState = ScanStateIdle,
            .initted = false,
            .ftarget = -1.0,
            .fsmooth = -1.0,
            .prevContrast = 0.0,
            .skipCount = 0,
            .stepCount = 0,
            .dropCount = 0,
            .scanMaxContrast = 0.0,
            .scanMinContrast = 1.0e9,
            .scanData = &[_]ScanRecord{},
            .reportState = AfStateIdle,
        };
    }

    pub fn name(self: *Af) []const u8 {
        return NAME;
    }

    pub fn read(self: *Af, params: libcamera.YamlObject) !void {
        try self.cfg.read(params);
    }

    pub fn initialise(self: *Af) void {
        self.cfg.initialise();
    }

    pub fn switchMode(self: *Af, cameraMode: CameraMode, metadata: ?*Metadata) void {
        self.statsRegion = libcamera.Rectangle{
            .x = @intCast(i32, cameraMode.cropX),
            .y = @intCast(i32, cameraMode.cropY),
            .width = @intCast(u32, cameraMode.width * cameraMode.scaleX),
            .height = @intCast(u32, cameraMode.height * cameraMode.scaleY),
        };
        log.debug("switchMode: statsRegion: {},{},{},{}", .{ self.statsRegion.x, self.statsRegion.y, self.statsRegion.width, self.statsRegion.height });
        self.invalidateWeights();

        if (self.scanState >= ScanStateCoarse and self.scanState < ScanStateSettle) {
            self.startProgrammedScan();
        }
        self.skipCount = self.cfg.skipFrames;
    }

    fn computeWeights(self: *Af, wgts: *RegionWeights, rows: u32, cols: u32) void {
        wgts.rows = rows;
        wgts.cols = cols;
        wgts.sum = 0;
        wgts.w = &[_]u16{0} ** (rows * cols);

        if (rows > 0 and cols > 0 and self.useWindows and self.statsRegion.height >= rows and self.statsRegion.width >= cols) {
            const maxCellWeight = 46080 / (MaxWindows * rows * cols);
            const cellH = self.statsRegion.height / rows;
            const cellW = self.statsRegion.width / cols;
            const cellA = cellH * cellW;

            for (w in self.windows) {
                for (r in 0..rows) {
                    const y0 = std.math.max(self.statsRegion.y + @intCast(i32, cellH * r), w.y);
                    const y1 = std.math.min(self.statsRegion.y + @intCast(i32, cellH * (r + 1)), w.y + @intCast(i32, w.height));
                    if (y0 >= y1) continue;
                    const y1_adj = y1 - y0;
                    for (c in 0..cols) {
                        const x0 = std.math.max(self.statsRegion.x + @intCast(i32, cellW * c), w.x);
                        const x1 = std.math.min(self.statsRegion.x + @intCast(i32, cellW * (c + 1)), w.x + @intCast(i32, w.width));
                        if (x0 >= x1) continue;
                        const a = y1_adj * (x1 - x0);
                        const adj_a = (maxCellWeight * a + cellA - 1) / cellA;
                        wgts.w[r * cols + c] += adj_a;
                        wgts.sum += adj_a;
                    }
                }
            }
        }

        if (wgts.sum == 0) {
            for (r in rows / 3..rows - rows / 3) {
                for (c in cols / 4..cols - cols / 4) {
                    wgts.w[r * cols + c] = 1;
                    wgts.sum += 1;
                }
            }
        }
    }

    fn invalidateWeights(self: *Af) void {
        self.phaseWeights.sum = 0;
        self.contrastWeights.sum = 0;
    }

    fn getPhase(self: *Af, regions: PdafRegions, phase: *f64, conf: *f64) bool {
        const size = regions.size();
        if (size.height != self.phaseWeights.rows or size.width != self.phaseWeights.cols or self.phaseWeights.sum == 0) {
            log.debug("Recompute Phase weights {}x{}", .{ size.width, size.height });
            self.computeWeights(&self.phaseWeights, size.height, size.width);
        }

        var sumWc: u32 = 0;
        var sumWcp: i64 = 0;
        for (i in 0..regions.numRegions()) {
            const w = self.phaseWeights.w[i];
            if (w != 0) {
                const data = regions.get(i).val;
                var c = data.conf;
                if (c >= self.cfg.confThresh) {
                    if (c > self.cfg.confClip) c = self.cfg.confClip;
                    c -= (self.cfg.confThresh >> 2);
                    sumWc += w * c;
                    c -= (self.cfg.confThresh >> 2);
                    sumWcp += @intCast(i64, w * c) * @intCast(i64, data.phase);
                }
            }
        }

        if (0 < self.phaseWeights.sum and self.phaseWeights.sum <= sumWc) {
            phase.* = @intToFloat(f64, sumWcp) / @intToFloat(f64, sumWc);
            conf.* = @intToFloat(f64, sumWc) / @intToFloat(f64, self.phaseWeights.sum);
            return true;
        } else {
            phase.* = 0.0;
            conf.* = 0.0;
            return false;
        }
    }

    fn getContrast(self: *Af, focusStats: FocusRegions) f64 {
        const size = focusStats.size();
        if (size.height != self.contrastWeights.rows or size.width != self.contrastWeights.cols or self.contrastWeights.sum == 0) {
            log.debug("Recompute Contrast weights {}x{}", .{ size.width, size.height });
            self.computeWeights(&self.contrastWeights, size.height, size.width);
        }

        var sumWc: u64 = 0;
        for (i in 0..focusStats.numRegions()) {
            sumWc += self.contrastWeights.w[i] * focusStats.get(i).val;
        }

        return if (self.contrastWeights.sum > 0) @intToFloat(f64, sumWc) / @intToFloat(f64, self.contrastWeights.sum) else 0.0;
    }

    fn doPDAF(self: *Af, phase: f64, conf: f64) void {
        var phase_adj = phase * self.cfg.speeds[self.speed].pdafGain;

        if (self.mode == AfModeContinuous) {
            phase_adj *= conf / (conf + self.cfg.confEpsilon);
            if (std.math.abs(phase_adj) < self.cfg.speeds[self.speed].pdafSquelch) {
                const a = phase_adj / self.cfg.speeds[self.speed].pdafSquelch;
                phase_adj *= a * a;
            }
        } else {
            if (self.stepCount >= self.cfg.speeds[self.speed].stepFrames) {
                if (std.math.abs(phase_adj) < self.cfg.speeds[self.speed].pdafSquelch) {
                    self.stepCount = self.cfg.speeds[self.speed].stepFrames;
                }
            } else {
                phase_adj *= self.stepCount / self.cfg.speeds[self.speed].stepFrames;
            }
        }

        if (phase_adj < -self.cfg.speeds[self.speed].maxSlew) {
            phase_adj = -self.cfg.speeds[self.speed].maxSlew;
            self.reportState = if (self.ftarget <= self.cfg.ranges[self.range].focusMin) AfStateFailed else AfStateScanning;
        } else if (phase_adj > self.cfg.speeds[self.speed].maxSlew) {
            phase_adj = self.cfg.speeds[self.speed].maxSlew;
            self.reportState = if (self.ftarget >= self.cfg.ranges[self.range].focusMax) AfStateFailed else AfStateScanning;
        } else {
            self.reportState = AfStateFocused;
        }

        self.ftarget = self.fsmooth + phase_adj;
    }

    fn earlyTerminationByPhase(self: *Af, phase: f64) bool {
        if (self.scanData.len > 0 and self.scanData[self.scanData.len - 1].conf >= self.cfg.confEpsilon) {
            const oldFocus = self.scanData[self.scanData.len - 1].focus;
            const oldPhase = self.scanData[self.scanData.len - 1].phase;

            if ((self.ftarget - oldFocus) * (phase - oldPhase) > 0.0) {
                const param = phase / (phase - oldPhase);
                if (-3.0 <= param and param <= 3.5) {
                    self.ftarget += param * (oldFocus - self.ftarget);
                    log.debug("ETBP: param={}", .{ param });
                    return true;
                }
            }
        }

        return false;
    }

    fn findPeak(self: *Af, i: u32) f64 {
        var f = self.scanData[i].focus;

        if (i > 0 and i + 1 < self.scanData.len) {
            const dropLo = self.scanData[i].contrast - self.scanData[i - 1].contrast;
            const dropHi = self.scanData[i].contrast - self.scanData[i + 1].contrast;
            if (0.0 <= dropLo and dropLo < dropHi) {
                const param = 0.3125 * (1.0 - dropLo / dropHi) * (1.6 - dropLo / dropHi);
                f += param * (self.scanData[i - 1].focus - f);
            } else if (0.0 <= dropHi and dropHi < dropLo) {
                const param = 0.3125 * (1.0 - dropHi / dropLo) * (1.6 - dropHi / dropLo);
                f += param * (self.scanData[i + 1].focus - f);
            }
        }

        log.debug("FindPeak: {}", .{ f });
        return f;
    }

    fn doScan(self: *Af, contrast: f64, phase: f64, conf: f64) void {
        if (self.scanData.len == 0 or contrast > self.scanMaxContrast) {
            self.scanMaxContrast = contrast;
            self.scanMaxIndex = self.scanData.len;
        }
        if (contrast < self.scanMinContrast) {
            self.scanMinContrast = contrast;
        }
        self.scanData.append(ScanRecord{ .focus = self.ftarget, .contrast = contrast, .phase = phase, .conf = conf });

        if (self.scanState == ScanStateCoarse) {
            if (self.ftarget >= self.cfg.ranges[self.range].focusMax or contrast < self.cfg.speeds[self.speed].contrastRatio * self.scanMaxContrast) {
                self.ftarget = std.math.min(self.ftarget, self.findPeak(self.scanMaxIndex) + 2.0 * self.cfg.speeds[self.speed].stepFine);
                self.scanState = ScanStateFine;
                self.scanData.clear();
            } else {
                self.ftarget += self.cfg.speeds[self.speed].stepCoarse;
            }
        } else {
            if (self.ftarget <= self.cfg.ranges[self.range].focusMin or self.scanData.len >= 5 or contrast < self.cfg.speeds[self.speed].contrastRatio * self.scanMaxContrast) {
                self.ftarget = self.findPeak(self.scanMaxIndex);
                self.scanState = ScanStateSettle;
            } else {
                self.ftarget -= self.cfg.speeds[self.speed].stepFine;
            }
        }

        self.stepCount = if (self.ftarget == self.fsmooth) 0 else self.cfg.speeds[self.speed].stepFrames;
    }

    fn doAF(self: *Af, contrast: f64, phase: f64, conf: f64) void {
        if (self.skipCount > 0) {
            log.debug("SKIP");
            self.skipCount -= 1;
            return;
        }

        if (self.scanState == ScanStatePdaf) {
            if (conf > (if (self.dropCount != 0) 1.0 else 0.25) * self.cfg.confEpsilon) {
                self.doPDAF(phase, conf);
                if (self.stepCount > 0) {
                    self.stepCount -= 1;
                } else if (self.mode != AfModeContinuous) {
                    self.scanState = ScanStateIdle;
                }
                self.dropCount = 0;
            } else if (self.dropCount += 1 == self.cfg.speeds[self.speed].dropoutFrames) {
                self.startProgrammedScan();
            }
        } else if (self.scanState >= ScanStateCoarse and self.fsmooth == self.ftarget) {
            if (self.stepCount > 0) {
                self.stepCount -= 1;
            } else if (self.scanState == ScanStateSettle) {
                if (self.prevContrast >= self.cfg.speeds[self.speed].contrastRatio * self.scanMaxContrast and self.scanMinContrast <= self.cfg.speeds[self.speed].contrastRatio * self.scanMaxContrast) {
                    self.reportState = AfStateFocused;
                } else {
                    self.reportState = AfStateFailed;
                }
                if (self.mode == AfModeContinuous and not self.pauseFlag and self.cfg.speeds[self.speed].dropoutFrames > 0) {
                    self.scanState = ScanStatePdaf;
                } else {
                    self.scanState = ScanStateIdle;
                }
                self.scanData.clear();
            } else if (conf >= self.cfg.confEpsilon and self.earlyTerminationByPhase(phase)) {
                self.scanState = ScanStateSettle;
                self.stepCount = if (self.mode == AfModeContinuous) 0 else self.cfg.speeds[self.speed].stepFrames;
            } else {
                self.doScan(contrast, phase, conf);
            }
        }
    }

    fn updateLensPosition(self: *Af) void {
        if (self.scanState >= ScanStatePdaf) {
            self.ftarget = std.math.clamp(self.ftarget, self.cfg.ranges[self.range].focusMin, self.cfg.ranges[self.range].focusMax);
        }

        if (self.initted) {
            self.fsmooth = std.math.clamp(self.ftarget, self.fsmooth - self.cfg.speeds[self.speed].maxSlew, self.fsmooth + self.cfg.speeds[self.speed].maxSlew);
        } else {
            self.fsmooth = self.ftarget;
            self.initted = true;
            self.skipCount = self.cfg.skipFrames;
        }
    }

    fn startAF(self: *Af) void {
        if (self.cfg.speeds[self.speed].dropoutFrames > 0 and (self.mode == AfModeContinuous or self.cfg.speeds[self.speed].pdafFrames > 0)) {
            if (not self.initted) {
                self.ftarget = self.cfg.ranges[self.range].focusDefault;
                self.updateLensPosition();
            }
            self.stepCount = if (self.mode == AfModeContinuous) 0 else self.cfg.speeds[self.speed].pdafFrames;
            self.scanState = ScanStatePdaf;
            self.scanData.clear();
            self.dropCount = 0;
            self.reportState = AfStateScanning;
        } else {
            self.startProgrammedScan();
        }
    }

    fn startProgrammedScan(self: *Af) void {
        self.ftarget = self.cfg.ranges[self.range].focusMin;
        self.updateLensPosition();
        self.scanState = ScanStateCoarse;
        self.scanMaxContrast = 0.0;
        self.scanMinContrast = 1.0e9;
        self.scanMaxIndex = 0;
        self.scanData.clear();
        self.stepCount = self.cfg.speeds[self.speed].stepFrames;
        self.reportState = AfStateScanning;
    }

    fn goIdle(self: *Af) void {
        self.scanState = ScanStateIdle;
        self.reportState = AfStateIdle;
        self.scanData.clear();
    }

    pub fn prepare(self: *Af, imageMetadata: *Metadata) void {
        if (self.scanState == ScanStateTrigger) {
            self.startAF();
        }

        if (self.initted) {
            const regions = PdafRegions{};
            var phase: f64 = 0.0;
            var conf: f64 = 0.0;
            const oldFt = self.ftarget;
            const oldFs = self.fsmooth;
            const oldSs = self.scanState;
            const oldSt = self.stepCount;
            if (imageMetadata.get("pdaf.regions", &regions) == 0) {
                self.getPhase(regions, &phase, &conf);
            }
            self.doAF(self.prevContrast, phase, conf);
            self.updateLensPosition();
            log.debug("{:u} sst{:u}->{:u} stp{:u}->{:u} ft{:.2}->{:.2} fs{:.2}->{:.2} cont={} phase={} conf={}", .{ @intCast(u32, self.reportState), @intCast(u32, oldSs), @intCast(u32, self.scanState), oldSt, self.stepCount, oldFt, self.ftarget, oldFs, self.fsmooth, @intCast(i32, self.prevContrast), @intCast(i32, phase), @intCast(i32, conf) });
        }

        const status = AfStatus{
            .pauseState = if (self.pauseFlag) if (self.scanState == ScanStateIdle) AfPauseStatePaused else AfPauseStatePausing else AfPauseStateRunning,
            .state = if (self.mode == AfModeAuto and self.scanState != ScanStateIdle) AfStateScanning else self.reportState,
            .lensSetting = if (self.initted) ?@intCast(i32, self.cfg.map.eval(self.fsmooth)) else null,
        };
        imageMetadata.set("af.status", status);
    }

    pub fn process(self: *Af, stats: *Statistics, imageMetadata: ?*Metadata) void {
        self.prevContrast = self.getContrast(stats.focusRegions);
    }

    pub fn setRange(self: *Af, r: AfRange) void {
        log.debug("setRange: {}", .{ @intCast(u32, r) });
        if (r < AfRangeMax) {
            self.range = r;
        }
    }

    pub fn setSpeed(self: *Af, s: AfSpeed) void {
        log.debug("setSpeed: {}", .{ @intCast(u32, s) });
        if (s < AfSpeedMax) {
            if (self.scanState == ScanStatePdaf and self.cfg.speeds[s].pdafFrames > self.cfg.speeds[self.speed].pdafFrames) {
                self.stepCount += self.cfg.speeds[s].pdafFrames - self.cfg.speeds[self.speed].pdafFrames;
            }
            self.speed = s;
        }
    }

    pub fn setMetering(self: *Af, mode: bool) void {
        if (self.useWindows != mode) {
            self.useWindows = mode;
            self.invalidateWeights();
        }
    }

    pub fn setWindows(self: *Af, wins: []const libcamera.Rectangle) void {
        self.windows.clear();
        for (w in wins) {
            log.debug("Window: {}, {}, {}, {}", .{ w.x, w.y, w.width, w.height });
            self.windows.append(w);
            if (self.windows.len >= MaxWindows) {
                break;
            }
        }

        if (self.useWindows) {
            self.invalidateWeights();
        }
    }

    pub fn setLensPosition(self: *Af, dioptres: f64, hwpos: ?*i32) bool {
        var changed = false;

        if (self.mode == AfModeManual) {
            log.debug("setLensPosition: {}", .{ dioptres });
            self.ftarget = self.cfg.map.domain().clamp(dioptres);
            changed = not (self.initted and self.fsmooth == self.ftarget);
            self.updateLensPosition();
        }

        if (hwpos) {
            hwpos.* = @intCast(i32, self.cfg.map.eval(self.fsmooth));
        }

        return changed;
    }

    pub fn getLensPosition(self: *Af) ?f64 {
        return if (self.initted) ?self.fsmooth else null;
    }

    pub fn cancelScan(self: *Af) void {
        log.debug("cancelScan");
        if (self.mode == AfModeAuto) {
            self.goIdle();
        }
    }

    pub fn triggerScan(self: *Af) void {
        log.debug("triggerScan");
        if (self.mode == AfModeAuto and self.scanState == ScanStateIdle) {
            self.scanState = ScanStateTrigger;
        }
    }

    pub fn setMode(self: *Af, mode: AfMode) void {
        log.debug("setMode: {}", .{ @intCast(u32, mode) });
        if (self.mode != mode) {
            self.mode = mode;
            self.pauseFlag = false;
            if (mode == AfModeContinuous) {
                self.scanState = ScanStateTrigger;
            } else if (mode != AfModeAuto or self.scanState < ScanStateCoarse) {
                self.goIdle();
            }
        }
    }

    pub fn getMode(self: *Af) AfMode {
        return self.mode;
    }

    pub fn pause(self: *Af, pause: AfPause) void {
        log.debug("pause: {}", .{ @intCast(u32, pause) });
        if (self.mode == AfModeContinuous) {
            if (pause == AfPauseResume and self.pauseFlag) {
                self.pauseFlag = false;
                if (self.scanState < ScanStateCoarse) {
                    self.scanState = ScanStateTrigger;
                }
            } else if (pause != AfPauseResume and not self.pauseFlag) {
                self.pauseFlag = true;
                if (pause == AfPauseImmediate or self.scanState < ScanStateCoarse) {
                    self.goIdle();
                }
            }
        }
    }
};

const ScanState = enum {
    Idle,
    Trigger,
    Pdaf,
    Coarse,
    Fine,
    Settle,
};

const RangeDependentParams = struct {
    focusMin: f64,
    focusMax: f64,
    focusDefault: f64,

    pub fn init() RangeDependentParams {
        return RangeDependentParams{
            .focusMin = 0.0,
            .focusMax = 12.0,
            .focusDefault = 1.0,
        };
    }

    pub fn read(self: *RangeDependentParams, params: libcamera.YamlObject) void {
        readNumber(&self.focusMin, params, "min");
        readNumber(&self.focusMax, params, "max");
        readNumber(&self.focusDefault, params, "default");
    }
};

const SpeedDependentParams = struct {
    stepCoarse: f64,
    stepFine: f64,
    contrastRatio: f64,
    pdafGain: f64,
    pdafSquelch: f64,
    maxSlew: f64,
    pdafFrames: u32,
    dropoutFrames: u32,
    stepFrames: u32,

    pub fn init() SpeedDependentParams {
        return SpeedDependentParams{
            .stepCoarse = 1.0,
            .stepFine = 0.25,
            .contrastRatio = 0.75,
            .pdafGain = -0.02,
            .pdafSquelch = 0.125,
            .maxSlew = 2.0,
            .pdafFrames = 20,
            .dropoutFrames = 6,
            .stepFrames = 4,
        };
    }

    pub fn read(self: *SpeedDependentParams, params: libcamera.YamlObject) void {
        readNumber(&self.stepCoarse, params, "step_coarse");
        readNumber(&self.stepFine, params, "step_fine");
        readNumber(&self.contrastRatio, params, "contrast_ratio");
        readNumber(&self.pdafGain, params, "pdaf_gain");
        readNumber(&self.pdafSquelch, params, "pdaf_squelch");
        readNumber(&self.maxSlew, params, "max_slew");
        readNumber(&self.pdafFrames, params, "pdaf_frames");
        readNumber(&self.dropoutFrames, params, "dropout_frames");
        readNumber(&self.stepFrames, params, "step_frames");
    }
};

const CfgParams = struct {
    ranges: [AfRangeMax]RangeDependentParams,
    speeds: [AfSpeedMax]SpeedDependentParams,
    confEpsilon: u32,
    confThresh: u32,
    confClip: u32,
    skipFrames: u32,
    map: libcamera.ipa.Pwl,

    pub fn init() CfgParams {
        return CfgParams{
            .ranges = [AfRangeMax]RangeDependentParams{
                RangeDependentParams.init(),
                RangeDependentParams.init(),
                RangeDependentParams.init(),
            },
            .speeds = [AfSpeedMax]SpeedDependentParams{
                SpeedDependentParams.init(),
                SpeedDependentParams.init(),
            },
            .confEpsilon = 8,
            .confThresh = 16,
            .confClip = 512,
            .skipFrames = 5,
            .map = libcamera.ipa.Pwl.init(),
        };
    }

    pub fn read(self: *CfgParams, params: libcamera.YamlObject) !void {
        if (params.contains("ranges")) {
            const rr = params.get("ranges").?;
            if (rr.contains("normal")) {
                self.ranges[AfRangeNormal].read(rr.get("normal").?);
            } else {
                log.warn("Missing range \"normal\"");
            }

            self.ranges[AfRangeMacro] = self.ranges[AfRangeNormal];
            if (rr.contains("macro")) {
                self.ranges[AfRangeMacro].read(rr.get("macro").?);
            }

            self.ranges[AfRangeFull].focusMin = std.math.min(self.ranges[AfRangeNormal].focusMin, self.ranges[AfRangeMacro].focusMin);
            self.ranges[AfRangeFull].focusMax = std.math.max(self.ranges[AfRangeNormal].focusMax, self.ranges[AfRangeMacro].focusMax);
            self.ranges[AfRangeFull].focusDefault = self.ranges[AfRangeNormal].focusDefault;
            if (rr.contains("full")) {
                self.ranges[AfRangeFull].read(rr.get("full").?);
            }
        } else {
            log.warn("No ranges defined");
        }

        if (params.contains("speeds")) {
            const ss = params.get("speeds").?;
            if (ss.contains("normal")) {
                self.speeds[AfSpeedNormal].read(ss.get("normal").?);
            } else {
                log.warn("Missing speed \"normal\"");
            }

            self.speeds[AfSpeedFast] = self.speeds[AfSpeedNormal];
            if (ss.contains("fast")) {
                self.speeds[AfSpeedFast].read(ss.get("fast").?);
            }
        } else {
            log.warn("No speeds defined");
        }

        readNumber(&self.confEpsilon, params, "conf_epsilon");
        readNumber(&self.confThresh, params, "conf_thresh");
        readNumber(&self.confClip, params, "conf_clip");
        readNumber(&self.skipFrames, params, "skip_frames");

        if (params.contains("map")) {
            self.map = params.get("map").?; // Assuming Pwl has a get method
        } else {
            log.warn("No map defined");
        }
    }

    pub fn initialise(self: *CfgParams) void {
        if (self.map.empty()) {
            const DefaultMapX0 = 0.0;
            const DefaultMapY0 = 445.0;
            const DefaultMapX1 = 15.0;
            const DefaultMapY1 = 925.0;

            self.map.append(DefaultMapX0, DefaultMapY0);
            self.map.append(DefaultMapX1, DefaultMapY1);
        }
    }
};

const ScanRecord = struct {
    focus: f64,
    contrast: f64,
    phase: f64,
    conf: f64,
};

const RegionWeights = struct {
    rows: u32,
    cols: u32,
    sum: u32,
    w: []u16,

    pub fn init() RegionWeights {
        return RegionWeights{
            .rows = 0,
            .cols = 0,
            .sum = 0,
            .w = &[_]u16{},
        };
    }
};

fn readNumber(comptime T: type, dest: *T, params: libcamera.YamlObject, name: []const u8) void {
    const value = params.get(name).get(T);
    if (value) {
        dest.* = value;
    } else {
        log.warn("Missing parameter \"{}\"", .{ name });
    }
}

fn create(controller: *Controller) *Algorithm {
    return &Algorithm(Af.init(controller));
}

const reg = RegisterAlgorithm(NAME, &create);

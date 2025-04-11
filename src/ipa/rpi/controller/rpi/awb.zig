const std = @import("std");
const libcamera = @import("libcamera");
const RPiController = @import("RPiController");
const AwbAlgorithm = @import("../awb_algorithm.zig").AwbAlgorithm;
const AwbStatus = @import("../awb_status.zig").AwbStatus;
const AlscStatus = @import("alsc_status.zig").AlscStatus;
const LuxStatus = @import("../lux_status.zig").LuxStatus;
const StatisticsPtr = @import("../statistics.zig").StatisticsPtr;

const kDefaultCT = 4500.0;

pub const AwbMode = struct {
    ctLo: f64,
    ctHi: f64,

    pub fn read(self: *AwbMode, params: YamlObject) !void {
        self.ctLo = try params.get("lo").get(f64);
        self.ctHi = try params.get("hi").get(f64);
    }
};

pub const AwbPrior = struct {
    lux: f64,
    prior: libcamera.ipa.Pwl,

    pub fn read(self: *AwbPrior, params: YamlObject) !void {
        self.lux = try params.get("lux").get(f64);
        self.prior = try params.get("prior").get(libcamera.ipa.Pwl);
    }
};

pub const AwbConfig = struct {
    defaultMode: ?*AwbMode,
    framePeriod: u16,
    startupFrames: u16,
    convergenceFrames: u32,
    speed: f64,
    ctR: libcamera.ipa.Pwl,
    ctB: libcamera.ipa.Pwl,
    ctRInverse: libcamera.ipa.Pwl,
    ctBInverse: libcamera.ipa.Pwl,
    priors: std.ArrayList(AwbPrior),
    modes: std.HashMap([]const u8, AwbMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn),
    minPixels: f64,
    minG: u16,
    minRegions: u32,
    deltaLimit: f64,
    coarseStep: f64,
    transversePos: f64,
    transverseNeg: f64,
    sensitivityR: f64,
    sensitivityB: f64,
    whitepointR: f64,
    whitepointB: f64,
    bayes: bool,
    biasProportion: f64,
    biasCT: f64,
    fast: bool,

    pub fn init() AwbConfig {
        return AwbConfig{
            .defaultMode = null,
            .framePeriod = 10,
            .startupFrames = 10,
            .convergenceFrames = 3,
            .speed = 0.05,
            .ctR = libcamera.ipa.Pwl.init(),
            .ctB = libcamera.ipa.Pwl.init(),
            .ctRInverse = libcamera.ipa.Pwl.init(),
            .ctBInverse = libcamera.ipa.Pwl.init(),
            .priors = std.ArrayList(AwbPrior).init(std.heap.page_allocator),
            .modes = std.HashMap([]const u8, AwbMode, std.hash_map.StringHashFn, std.hash_map.StringEqlFn).init(std.heap.page_allocator),
            .minPixels = 16.0,
            .minG = 32,
            .minRegions = 10,
            .deltaLimit = 0.2,
            .coarseStep = 0.2,
            .transversePos = 0.01,
            .transverseNeg = 0.01,
            .sensitivityR = 1.0,
            .sensitivityB = 1.0,
            .whitepointR = 0.0,
            .whitepointB = 0.0,
            .bayes = true,
            .biasProportion = 0.0,
            .biasCT = kDefaultCT,
            .fast = true,
        };
    }

    pub fn read(self: *AwbConfig, params: YamlObject) !void {
        self.bayes = params.get("bayes").getOptional(bool, true);
        self.framePeriod = params.get("frame_period").getOptional(u16, 10);
        self.startupFrames = params.get("startup_frames").getOptional(u16, 10);
        self.convergenceFrames = params.get("convergence_frames").getOptional(u32, 3);
        self.speed = params.get("speed").getOptional(f64, 0.05);

        if (params.contains("ct_curve")) {
            try self.readCtCurve(params.get("ct_curve"));
        }

        if (params.contains("priors")) {
            for (p in params.get("priors").asList()) |priorParams| {
                var prior = AwbPrior.init();
                try prior.read(priorParams);
                try self.priors.append(prior);
            }
        }

        if (params.contains("modes")) {
            for (entry in params.get("modes").asDict()) |key, value| {
                var mode = AwbMode.init();
                try mode.read(value);
                try self.modes.put(key, mode);
                if (self.defaultMode == null) {
                    self.defaultMode = &self.modes.get(key).?;
                }
            }
        }

        self.minPixels = params.get("min_pixels").getOptional(f64, 16.0);
        self.minG = params.get("min_G").getOptional(u16, 32);
        self.minRegions = params.get("min_regions").getOptional(u32, 10);
        self.deltaLimit = params.get("delta_limit").getOptional(f64, 0.2);
        self.coarseStep = params.get("coarse_step").getOptional(f64, 0.2);
        self.transversePos = params.get("transverse_pos").getOptional(f64, 0.01);
        self.transverseNeg = params.get("transverse_neg").getOptional(f64, 0.01);
        self.sensitivityR = params.get("sensitivity_r").getOptional(f64, 1.0);
        self.sensitivityB = params.get("sensitivity_b").getOptional(f64, 1.0);
        self.whitepointR = params.get("whitepoint_r").getOptional(f64, 0.0);
        self.whitepointB = params.get("whitepoint_b").getOptional(f64, 0.0);
        self.biasProportion = params.get("bias_proportion").getOptional(f64, 0.0);
        self.biasCT = params.get("bias_ct").getOptional(f64, kDefaultCT);
        self.fast = params.get("fast").getOptional(bool, self.bayes);
    }

    fn readCtCurve(self: *AwbConfig, params: YamlObject) !void {
        if (params.size() % 3 != 0) {
            return error.InvalidCtCurveEntry;
        }

        if (params.size() < 6) {
            return error.InsufficientPointsInCtCurve;
        }

        const list = params.asList();
        var it = list.iterator();
        while (it.next()) |ctValue| {
            const ct = try ctValue.get(f64);
            const rValue = try it.next().?.get(f64);
            const bValue = try it.next().?.get(f64);
            self.ctR.append(ct, rValue);
            self.ctB.append(ct, bValue);
        }

        self.ctRInverse = self.ctR.inverse().first;
        self.ctBInverse = self.ctB.inverse().first;
    }
};

pub const Awb = struct {
    awbAlgorithm: AwbAlgorithm,
    config: AwbConfig,
    asyncThread: std.Thread,
    mutex: std.Mutex,
    asyncSignal: std.Thread.Condition,
    syncSignal: std.Thread.Condition,
    asyncFinished: bool,
    asyncStart: bool,
    asyncAbort: bool,
    asyncStarted: bool,
    framePhase: i32,
    frameCount: i32,
    syncResults: AwbStatus,
    prevSyncResults: AwbStatus,
    modeName: []const u8,
    statistics: ?StatisticsPtr,
    mode: ?*AwbMode,
    lux: f64,
    asyncResults: AwbStatus,
    zones: std.ArrayList(RGB),
    points: std.ArrayList(libcamera.ipa.Pwl.Point),
    manualR: f64,
    manualB: f64,

    pub fn init(controller: *Controller) Awb {
        return Awb{
            .awbAlgorithm = AwbAlgorithm.init(controller),
            .config = AwbConfig.init(),
            .asyncThread = undefined,
            .mutex = std.Mutex.init(),
            .asyncSignal = std.Thread.Condition.init(),
            .syncSignal = std.Thread.Condition.init(),
            .asyncFinished = false,
            .asyncStart = false,
            .asyncAbort = false,
            .asyncStarted = false,
            .framePhase = 0,
            .frameCount = 0,
            .syncResults = AwbStatus.init(),
            .prevSyncResults = AwbStatus.init(),
            .modeName = "",
            .statistics = null,
            .mode = null,
            .lux = 0.0,
            .asyncResults = AwbStatus.init(),
            .zones = std.ArrayList(RGB).init(std.heap.page_allocator),
            .points = std.ArrayList(libcamera.ipa.Pwl.Point).init(std.heap.page_allocator),
            .manualR = 0.0,
            .manualB = 0.0,
        };
    }

    pub fn name(self: *const Awb) []const u8 {
        return "rpi.awb";
    }

    pub fn read(self: *Awb, params: YamlObject) !void {
        try self.config.read(params);
    }

    pub fn initialise(self: *Awb) void {
        self.frameCount = 0;
        self.framePhase = 0;

        if (!self.config.ctR.empty() and !self.config.ctB.empty()) {
            self.syncResults.temperatureK = self.config.ctR.domain().clamp(4000);
            self.syncResults.gainR = 1.0 / self.config.ctR.eval(self.syncResults.temperatureK);
            self.syncResults.gainG = 1.0;
            self.syncResults.gainB = 1.0 / self.config.ctB.eval(self.syncResults.temperatureK);
        } else {
            self.syncResults.temperatureK = kDefaultCT;
            self.syncResults.gainR = 1.0;
            self.syncResults.gainG = 1.0;
            self.syncResults.gainB = 1.0;
        }

        self.prevSyncResults = self.syncResults;
        self.asyncResults = self.syncResults;
    }

    pub fn initialValues(self: *Awb, gainR: *f64, gainB: *f64) void {
        gainR.* = self.syncResults.gainR;
        gainB.* = self.syncResults.gainB;
    }

    pub fn disableAuto(self: *Awb) void {
        self.manualR = self.syncResults.gainR = self.prevSyncResults.gainR;
        self.manualB = self.syncResults.gainB = self.prevSyncResults.gainB;
        self.syncResults.gainG = self.prevSyncResults.gainG;
        self.syncResults.temperatureK = self.prevSyncResults.temperatureK;
    }

    pub fn enableAuto(self: *Awb) void {
        self.manualR = 0.0;
        self.manualB = 0.0;
    }

    pub fn getConvergenceFrames(self: *const Awb) u32 {
        if (!self.isAutoEnabled()) {
            return 0;
        } else {
            return self.config.convergenceFrames;
        }
    }

    pub fn setMode(self: *Awb, modeName: []const u8) void {
        self.modeName = modeName;
    }

    pub fn setManualGains(self: *Awb, manualR: f64, manualB: f64) void {
        self.manualR = manualR;
        self.manualB = manualB;

        if (!self.isAutoEnabled()) {
            self.syncResults.gainR = self.prevSyncResults.gainR = self.manualR;
            self.syncResults.gainG = self.prevSyncResults.gainG = 1.0;
            self.syncResults.gainB = self.prevSyncResults.gainB = self.manualB;

            if (self.config.bayes) {
                const ctR = self.config.ctRInverse.eval(self.config.ctRInverse.domain().clamp(1 / self.manualR));
                const ctB = self.config.ctBInverse.eval(self.config.ctBInverse.domain().clamp(1 / self.manualB));
                self.prevSyncResults.temperatureK = (ctR + ctB) / 2;
                self.syncResults.temperatureK = self.prevSyncResults.temperatureK;
            }
        }
    }

    pub fn setColourTemperature(self: *Awb, temperatureK: f64) void {
        if (!self.config.bayes) {
            std.log.warn("AWB uncalibrated - cannot set colour temperature");
            return;
        }

        temperatureK = self.config.ctR.domain().clamp(temperatureK);
        self.manualR = 1 / self.config.ctR.eval(temperatureK);
        self.manualB = 1 / self.config.ctB.eval(temperatureK);

        self.syncResults.temperatureK = temperatureK;
        self.syncResults.gainR = self.manualR;
        self.syncResults.gainG = 1.0;
        self.syncResults.gainB = self.manualB;
        self.prevSyncResults = self.syncResults;
    }

    pub fn switchMode(self: *Awb, cameraMode: CameraMode, metadata: *Metadata) void {
        metadata.set("awb.status", self.prevSyncResults);
    }

    fn isAutoEnabled(self: *const Awb) bool {
        return self.manualR == 0.0 or self.manualB == 0.0;
    }

    fn fetchAsyncResults(self: *Awb) void {
        std.log.debug("Fetch AWB results");
        self.asyncFinished = false;
        self.asyncStarted = false;

        if (self.isAutoEnabled()) {
            self.syncResults = self.asyncResults;
        }
    }

    fn restartAsync(self: *Awb, stats: StatisticsPtr, lux: f64) void {
        std.log.debug("Starting AWB calculation");
        self.statistics = stats;
        const m = self.config.modes.get(self.modeName);
        self.mode = m orelse self.config.defaultMode;
        self.lux = lux;
        self.framePhase = 0;
        self.asyncStarted = true;
        self.asyncResults.mode = self.modeName;
        self.asyncStart = true;
        self.asyncSignal.broadcast();
    }

    pub fn prepare(self: *Awb, imageMetadata: *Metadata) void {
        if (self.frameCount < @intCast(i32, self.config.startupFrames)) {
            self.frameCount += 1;
        }

        const speed = if (self.frameCount < @intCast(i32, self.config.startupFrames)) 1.0 else self.config.speed;
        std.log.debug("frame_count {d} speed {f}", .{ self.frameCount, speed });

        if (self.asyncStarted and self.asyncFinished) {
            self.fetchAsyncResults();
        }

        std.mem.copy(self.prevSyncResults.mode, self.syncResults.mode);
        self.prevSyncResults.temperatureK = speed * self.syncResults.temperatureK + (1.0 - speed) * self.prevSyncResults.temperatureK;
        self.prevSyncResults.gainR = speed * self.syncResults.gainR + (1.0 - speed) * self.prevSyncResults.gainR;
        self.prevSyncResults.gainG = speed * self.syncResults.gainG + (1.0 - speed) * self.prevSyncResults.gainG;
        self.prevSyncResults.gainB = speed * self.syncResults.gainB + (1.0 - speed) * self.prevSyncResults.gainB;
        imageMetadata.set("awb.status", self.prevSyncResults);
        std.log.debug("Using AWB gains r {f} g {f} b {f}", .{ self.prevSyncResults.gainR, self.prevSyncResults.gainG, self.prevSyncResults.gainB });
    }

    pub fn process(self: *Awb, stats: StatisticsPtr, imageMetadata: *Metadata) void {
        if (self.framePhase < @intCast(i32, self.config.framePeriod)) {
            self.framePhase += 1;
        }

        std.log.debug("frame_phase {d}", .{ self.framePhase });

        if (self.isAutoEnabled() and (self.framePhase >= @intCast(i32, self.config.framePeriod) or self.frameCount < @intCast(i32, self.config.startupFrames))) {
            var luxStatus = LuxStatus.init();
            luxStatus.lux = 400;
            if (imageMetadata.get("lux.status", &luxStatus) != 0) {
                std.log.debug("No lux metadata found");
            }

            std.log.debug("Awb lux value is {f}", .{ luxStatus.lux });

            if (!self.asyncStarted) {
                self.restartAsync(stats, luxStatus.lux);
            }
        }
    }

    fn asyncFunc(self: *Awb) void {
        while (true) {
            self.asyncSignal.wait(self.mutex, self.asyncStart or self.asyncAbort);
            self.asyncStart = false;
            if (self.asyncAbort) break;
            self.doAwb();
            self.asyncFinished = true;
            self.syncSignal.broadcast();
        }
    }

    fn generateStats(self: *Awb) void {
        self.zones.clear();
        const biasCtR = if (self.config.bayes) self.config.ctR.eval(self.config.biasCT) else 0;
        const biasCtB = if (self.config.bayes) self.config.ctB.eval(self.config.biasCT) else 0;
        generateStats(self.zones, self.statistics, self.config.minPixels, self.config.minG, self.getGlobalMetadata(), self.config.biasProportion, biasCtR, biasCtB);

        for (zone in self.zones.items) |*zone| {
            zone.R *= self.config.sensitivityR;
            zone.B *= self.config.sensitivityB;
        }
    }

    fn computeDelta2Sum(self: *Awb, gainR: f64, gainB: f64) f64 {
        var delta2Sum = 0.0;
        for (zone in self.zones.items) |*z| {
            const deltaR = gainR * z.R - 1 - self.config.whitepointR;
            const deltaB = gainB * z.B - 1 - self.config.whitepointB;
            var delta2 = deltaR * deltaR + deltaB * deltaB;
            delta2 = std.math.min(delta2, self.config.deltaLimit);
            delta2Sum += delta2;
        }
        return delta2Sum;
    }

    fn interpolatePrior(self: *Awb) libcamera.ipa.Pwl {
        if (self.lux <= self.config.priors.items[0].lux) {
            return self.config.priors.items[0].prior;
        } else if (self.lux >= self.config.priors.items[self.config.priors.items.len - 1].lux) {
            return self.config.priors.items[self.config.priors.items.len - 1].prior;
        } else {
            var idx = 0;
            while (self.config.priors.items[idx + 1].lux < self.lux) {
                idx += 1;
            }
            const lux0 = self.config.priors.items[idx].lux;
            const lux1 = self.config.priors.items[idx + 1].lux;
            return libcamera.ipa.Pwl.combine(self.config.priors.items[idx].prior, self.config.priors.items[idx + 1].prior, (x, y0, y1) => y0 + (y1 - y0) * (self.lux - lux0) / (lux1 - lux0));
        }
    }

    fn interpolateQuadatric(a: libcamera.ipa.Pwl.Point, b: libcamera.ipa.Pwl.Point, c: libcamera.ipa.Pwl.Point) f64 {
        const eps = 1e-3;
        const ca = c - a;
        const ba = b - a;
        const denominator = 2 * (ba.y() * ca.x() - ca.y() * ba.x());
        if (std.math.abs(denominator) > eps) {
            const numerator = ba.y() * ca.x() * ca.x() - ca.y() * ba.x() * ba.x();
            const result = numerator / denominator + a.x();
            return std.math.max(a.x(), std.math.min(c.x(), result));
        }
        return a.y() < c.y() - eps ? a.x() : (c.y() < a.y() - eps ? c.x() : b.x());
    }

    fn coarseSearch(self: *Awb, prior: libcamera.ipa.Pwl) f64 {
        self.points.clear();
        var bestPoint = 0;
        var t = self.mode.ctLo;
        var spanR = 0;
        var spanB = 0;

        while (true) {
            const r = self.config.ctR.eval(t, &spanR);
            const b = self.config.ctB.eval(t, &spanB);
            const gainR = 1 / r;
            const gainB = 1 / b;
            const delta2Sum = self.computeDelta2Sum(gainR, gainB);
            const priorLogLikelihood = prior.eval(prior.domain().clamp(t));
            const finalLogLikelihood = delta2Sum - priorLogLikelihood;
            std.log.debug("t: {f} gain R {f} gain B {f} delta2_sum {f} prior {f} final {f}", .{ t, gainR, gainB, delta2Sum, priorLogLikelihood, finalLogLikelihood });
            self.points.append(libcamera.ipa.Pwl.Point{ .x = t, .y = finalLogLikelihood });
            if (self.points.items[self.points.items.len - 1].y < self.points.items[bestPoint].y) {
                bestPoint = self.points.items.len - 1;
            }
            if (t == self.mode.ctHi) break;
            t = std.math.min(t + t / 10 * self.config.coarseStep, self.mode.ctHi);
        }

        t = self.points.items[bestPoint].x;
        std.log.debug("Coarse search found CT {f}", .{ t });

        if (self.points.items.len > 2) {
            const bp = std.math.min(bestPoint, self.points.items.len - 2);
            bestPoint = std.math.max(1, bp);
            t = self.interpolateQuadatric(self.points.items[bestPoint - 1], self.points.items[bestPoint], self.points.items[bestPoint + 1]);
            std.log.debug("After quadratic refinement, coarse search has CT {f}", .{ t });
        }

        return t;
    }

    fn fineSearch(self: *Awb, t: *f64, r: *f64, b: *f64, prior: libcamera.ipa.Pwl) void {
        var spanR = -1;
        var spanB = -1;
        self.config.ctR.eval(t.*, &spanR);
        self.config.ctB.eval(t.*, &spanB);
        const step = t.* / 10 * self.config.coarseStep * 0.1;
        var nsteps = 5;
        const rDiff = self.config.ctR.eval(t.* + nsteps * step, &spanR) - self.config.ctR.eval(t.* - nsteps * step, &spanR);
        const bDiff = self.config.ctB.eval(t.* + nsteps * step, &spanB) - self.config.ctB.eval(t.* - nsteps * step, &spanB);
        const transverse = libcamera.ipa.Pwl.Point{ .x = bDiff, .y = -rDiff };
        if (transverse.length2() < 1e-6) return;

        const transverseRange = self.config.transverseNeg + self.config.transversePos;
        const maxNumDeltas = 12;
        var numDeltas = std.math.floor(transverseRange * 100 + 0.5) + 1;
        numDeltas = numDeltas < 3 ? 3 : (numDeltas > maxNumDeltas ? maxNumDeltas : numDeltas);
        nsteps += numDeltas;

        var bestLogLikelihood = 0.0;
        var bestT = 0.0;
        var bestR = 0.0;
        var bestB = 0.0;

        for (var i = -nsteps; i <= nsteps; i += 1) {
            const tTest = t.* + i * step;
            const priorLogLikelihood = prior.eval(prior.domain().clamp(tTest));
            const rCurve = self.config.ctR.eval(tTest, &spanR);
            const bCurve = self.config.ctB.eval(tTest, &spanB);
            var points = std.ArrayList(libcamera.ipa.Pwl.Point).init(std.heap.page_allocator);
            var bestPoint = 0;

            for (var j = 0; j < numDeltas; j += 1) {
                points.append(libcamera.ipa.Pwl.Point{ .x = -self.config.transverseNeg + (transverseRange * j) / (numDeltas - 1) });
                const rbTest = libcamera.ipa.Pwl.Point{ .x = rCurve, .y = bCurve } + transverse * points.items[j].x;
                const rTest = rbTest.x;
                const bTest = rbTest.y;
                const gainR = 1 / rTest;
                const gainB = 1 / bTest;
                const delta2Sum = self.computeDelta2Sum(gainR, gainB);
                points.items[j].y = delta2Sum - priorLogLikelihood;
                std.log.debug("At t {f} r {f} b {f}: {f}", .{ tTest, rTest, bTest, points.items[j].y });
                if (points.items[j].y < points.items[bestPoint].y) {
                    bestPoint = j;
                }
            }

            bestPoint = std.math.max(1, std.math.min(bestPoint, numDeltas - 2));
            const rbTest = libcamera.ipa.Pwl.Point{ .x = rCurve, .y = bCurve } + transverse * self.interpolateQuadatric(points.items[bestPoint - 1], points.items[bestPoint], points.items[bestPoint + 1]);
            const rTest = rbTest.x;
            const bTest = rbTest.y;
            const gainR = 1 / rTest;
            const gainB = 1 / bTest;
            const delta2Sum = self.computeDelta2Sum(gainR, gainB);
            const finalLogLikelihood = delta2Sum - priorLogLikelihood;
            std.log.debug("Finally {f} r {f} b {f}: {f} {s}", .{ tTest, rTest, bTest, finalLogLikelihood, if (finalLogLikelihood < bestLogLikelihood) "BEST" else "" });
            if (bestT == 0 or finalLogLikelihood < bestLogLikelihood) {
                bestLogLikelihood = finalLogLikelihood;
                bestT = tTest;
                bestR = rTest;
                bestB = bTest;
            }
        }

        t.* = bestT;
        r.* = bestR;
        b.* = bestB;
        std.log.debug("Fine search found t {f} r {f} b {f}", .{ t.*, r.*, b.* });
    }

    fn awbBayes(self: *Awb) void {
        for (zone in self.zones.items) |*z| {
            z.R = z.R / (z.G + 1);
            z.B = z.B / (z.G + 1);
        }

        var prior = self.interpolatePrior();
        prior *= self.zones.items.len / @intCast(f64, self.statistics.awbRegions.numRegions());
        prior.map((x, y) => std.log.debug("({f},{f})", .{ x, y }));

        var t = self.coarseSearch(prior);
        var r = self.config.ctR.eval(t);
        var b = self.config.ctB.eval(t);
        std.log.debug("After coarse search: r {f} b {f} (gains r {f} b {f})", .{ r, b, 1 / r, 1 / b });

        self.fineSearch(&t, &r, &b, prior);
        std.log.debug("After fine search: r {f} b {f} (gains r {f} b {f})", .{ r, b, 1 / r, 1 / b });

        self.asyncResults.temperatureK = t;
        self.asyncResults.gainR = 1.0 / r * self.config.sensitivityR;
        self.asyncResults.gainG = 1.0;
        self.asyncResults.gainB = 1.0 / b * self.config.sensitivityB;
    }

    fn awbGrey(self: *Awb) void {
        std.log.debug("Grey world AWB");

        var derivsR = self.zones;
        var derivsB = self.zones;
        std.sort.sort(derivsR.items, (a, b) => a.G * b.R < b.G * a.R);
        std.sort.sort(derivsB.items, (a, b) => a.G * b.B < b.G * a.B);

        const discard = derivsR.items.len / 4;
        var sumR = RGB.init(0, 0, 0);
        var sumB = RGB.init(0, 0, 0);
        for (var i = discard; i < derivsR.items.len - discard; i += 1) {
            sumR += derivsR.items[i];
            sumB += derivsB.items[i];
        }

        const gainR = sumR.G / (sumR.R + 1);
        const gainB = sumB.G / (sumB.B + 1);

        self.asyncResults.temperatureK = kDefaultCT;
        self.asyncResults.gainR = gainR;
        self.asyncResults.gainG = 1.0;
        self.asyncResults.gainB = gainB;
    }

    fn doAwb(self: *Awb) void {
        self.generateStats();
        std.log.debug("Valid zones: {d}", .{ self.zones.items.len });
        if (self.zones.items.len > self.config.minRegions) {
            if (self.config.bayes) {
                self.awbBayes();
            } else {
                self.awbGrey();
            }
            std.log.debug("CT found is {f} with gains r {f} and b {f}", .{ self.asyncResults.temperatureK, self.asyncResults.gainR, self.asyncResults.gainB });
        }
        self.statistics = null;
    }
};

pub fn create(controller: *Controller) *Algorithm {
    return Awb.init(controller);
}

pub fn registerAlgorithm() void {
    RPiController.registerAlgorithm("rpi.awb", create);
}

const RGB = struct {
    R: f64,
    G: f64,
    B: f64,

    pub fn init(r: f64, g: f64, b: f64) RGB {
        return RGB{ .R = r, .G = g, .B = b };
    }

    pub fn add(self: *RGB, other: RGB) void {
        self.R += other.R;
        self.G += other.G;
        self.B += other.B;
    }
};

fn generateStats(zones: std.ArrayList(RGB), stats: StatisticsPtr, minPixels: f64, minG: f64, globalMetadata: Metadata, biasProportion: f64, biasCtR: f64, biasCtB: f64) void {
    const l = std.lock(globalMetadata);

    for (var i = 0; i < stats.awbRegions.numRegions(); i += 1) {
        var zone = RGB.init(0, 0, 0);
        const region = stats.awbRegions.get(i);
        if (region.counted >= minPixels) {
            zone.G = region.val.gSum / region.counted;
            if (zone.G < minG) continue;
            zone.R = region.val.rSum / region.counted;
            zone.B = region.val.bSum / region.counted;

            const proportion = biasProportion * region.counted;
            zone.R += proportion * biasCtR;
            zone.B += proportion * biasCtB;
            zone.G += proportion * 1.0;

            const alscStatus = globalMetadata.getLocked(AlscStatus, "alsc.status");
            if (stats.colourStatsPos == Statistics.ColourStatsPos.PreLsc and alscStatus) {
                zone.R *= alscStatus.r[i];
                zone.G *= alscStatus.g[i];
                zone.B *= alscStatus.b[i];
            }

            zones.append(zone);
        }
    }
}

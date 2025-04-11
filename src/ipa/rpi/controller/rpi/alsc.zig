const std = @import("std");
const libcamera = @import("libcamera");
const Algorithm = @import("../algorithm.zig").Algorithm;
const Metadata = @import("../metadata.zig").Metadata;
const StatisticsPtr = @import("../statistics.zig").StatisticsPtr;
const AwbStatus = @import("../awb_status.zig").AwbStatus;
const AlscStatus = @import("../alsc_status.zig").AlscStatus;
const RgbyRegions = @import("../statistics.zig").RgbyRegions;

const InsufficientData = -1.0;

pub const Alsc = struct {
    algorithm: Algorithm,
    asyncAbort: bool,
    asyncStart: bool,
    asyncStarted: bool,
    asyncFinished: bool,
    asyncThread: std.Thread,
    config: AlscConfig,
    firstTime: bool,
    cameraMode: CameraMode,
    luminanceTable: Array2D(f64),
    asyncLambdaR: Array2D(f64),
    asyncLambdaB: Array2D(f64),
    lambdaR: Array2D(f64),
    lambdaB: Array2D(f64),
    tmpC: [5]Array2D(f64),
    tmpM: [3]SparseArray(f64),
    asyncResults: [3]Array2D(f64),
    prevSyncResults: [3]Array2D(f64),
    syncResults: [3]Array2D(f64),
    framePhase: i32,
    frameCount: i32,
    frameCount2: i32,
    ct: f64,
    statistics: RgbyRegions,
    mutex: std.Thread.Mutex,
    asyncSignal: std.Thread.Cond,
    syncSignal: std.Thread.Cond,

    pub fn init(controller: *Controller) Alsc {
        var alsc = Alsc{
            .algorithm = Algorithm.init(controller),
            .asyncAbort = false,
            .asyncStart = false,
            .asyncStarted = false,
            .asyncFinished = false,
            .asyncThread = undefined,
            .config = AlscConfig{},
            .firstTime = true,
            .cameraMode = CameraMode{},
            .luminanceTable = Array2D(f64).init(),
            .asyncLambdaR = Array2D(f64).init(),
            .asyncLambdaB = Array2D(f64).init(),
            .lambdaR = Array2D(f64).init(),
            .lambdaB = Array2D(f64).init(),
            .tmpC = undefined,
            .tmpM = undefined,
            .asyncResults = undefined,
            .prevSyncResults = undefined,
            .syncResults = undefined,
            .framePhase = 0,
            .frameCount = 0,
            .frameCount2 = 0,
            .ct = 0.0,
            .statistics = RgbyRegions.init(),
            .mutex = std.Thread.Mutex.init(),
            .asyncSignal = std.Thread.Cond.init(),
            .syncSignal = std.Thread.Cond.init(),
        };
        alsc.asyncThread = try std.Thread.spawn(alsc.asyncFunc);
        return alsc;
    }

    pub fn deinit(self: *Alsc) void {
        {
            const lock = self.mutex.lock();
            self.asyncAbort = true;
        }
        self.asyncSignal.broadcast();
        self.asyncThread.join();
    }

    pub fn name(self: *const Alsc) []const u8 {
        return "rpi.alsc";
    }

    pub fn read(self: *Alsc, params: YamlObject) !void {
        self.config.tableSize = self.algorithm.getHardwareConfig().awbRegions;
        self.config.framePeriod = params.get("frame_period").getOptional(u16, 12);
        self.config.startupFrames = params.get("startup_frames").getOptional(u16, 10);
        self.config.speed = params.get("speed").getOptional(f64, 0.05);
        const sigma = params.get("sigma").getOptional(f64, 0.01);
        self.config.sigmaCr = params.get("sigma_Cr").getOptional(f64, sigma);
        self.config.sigmaCb = params.get("sigma_Cb").getOptional(f64, sigma);
        self.config.minCount = params.get("min_count").getOptional(f64, 10.0);
        self.config.minG = params.get("min_G").getOptional(u16, 50);
        self.config.omega = params.get("omega").getOptional(f64, 1.3);
        self.config.nIter = params.get("n_iter").getOptional(u32, self.config.tableSize.width + self.config.tableSize.height);
        self.config.luminanceStrength = params.get("luminance_strength").getOptional(f64, 1.0);

        self.config.luminanceLut.resize(self.config.tableSize, 1.0);
        var ret: i32 = 0;

        if (params.contains("corner_strength")) {
            ret = generateLut(self.config.luminanceLut, params);
        } else if (params.contains("luminance_lut")) {
            ret = readLut(self.config.luminanceLut, params.get("luminance_lut"));
        } else {
            std.log.warn("no luminance table - assume unity everywhere");
        }
        if (ret != 0) return error.Invalid;

        ret = readCalibrations(self.config.calibrationsCr, params, "calibrations_Cr", self.config.tableSize);
        if (ret != 0) return error.Invalid;
        ret = readCalibrations(self.config.calibrationsCb, params, "calibrations_Cb", self.config.tableSize);
        if (ret != 0) return error.Invalid;

        self.config.defaultCt = params.get("default_ct").getOptional(f64, 4500.0);
        self.config.threshold = params.get("threshold").getOptional(f64, 1e-3);
        self.config.lambdaBound = params.get("lambda_bound").getOptional(f64, 0.05);
    }

    pub fn initialise(self: *Alsc) void {
        self.frameCount2 = 0;
        self.frameCount = 0;
        self.framePhase = 0;
        self.firstTime = true;
        self.ct = self.config.defaultCt;

        const XY = self.config.tableSize.width * self.config.tableSize.height;

        for (r in self.syncResults) |*r| {
            r.resize(self.config.tableSize);
        }
        for (r in self.prevSyncResults) |*r| {
            r.resize(self.config.tableSize);
        }
        for (r in self.asyncResults) |*r| {
            r.resize(self.config.tableSize);
        }

        self.luminanceTable.resize(self.config.tableSize);
        self.asyncLambdaR.resize(self.config.tableSize);
        self.asyncLambdaB.resize(self.config.tableSize);
        self.lambdaR.resize(self.config.tableSize);
        self.lambdaB.resize(self.config.tableSize);

        for (c in self.tmpC) |*c| {
            c.resize(self.config.tableSize);
        }
        for (m in self.tmpM) |*m| {
            m.resize(XY);
        }
    }

    pub fn switchMode(self: *Alsc, cameraMode: CameraMode, metadata: *Metadata) void {
        const resetTables = self.firstTime or compareModes(self.cameraMode, cameraMode);

        self.ct = getCt(metadata, self.ct);

        self.waitForAsyncThread();

        self.cameraMode = cameraMode;

        resampleCalTable(self.config.luminanceLut, self.cameraMode, self.luminanceTable);

        if (resetTables) {
            std.mem.set(self.lambdaR.ptr(), 1.0);
            std.mem.set(self.lambdaB.ptr(), 1.0);
            var calTableR = self.tmpC[0];
            var calTableB = self.tmpC[1];
            var calTableTmp = self.tmpC[2];
            getCalTable(self.ct, self.config.calibrationsCr, calTableTmp);
            resampleCalTable(calTableTmp, self.cameraMode, calTableR);
            getCalTable(self.ct, self.config.calibrationsCb, calTableTmp);
            resampleCalTable(calTableTmp, self.cameraMode, calTableB);
            compensateLambdasForCal(calTableR, self.lambdaR, self.asyncLambdaR);
            compensateLambdasForCal(calTableB, self.lambdaB, self.asyncLambdaB);
            addLuminanceToTables(self.syncResults, self.asyncLambdaR, 1.0, self.asyncLambdaB, self.luminanceTable, self.config.luminanceStrength);
            self.prevSyncResults = self.syncResults;
            self.framePhase = self.config.framePeriod;
            self.firstTime = false;
        }
    }

    pub fn prepare(self: *Alsc, imageMetadata: *Metadata) void {
        if (self.frameCount < @intCast(i32, self.config.startupFrames)) {
            self.frameCount += 1;
        }
        const speed = self.frameCount < @intCast(i32, self.config.startupFrames) ? 1.0 : self.config.speed;
        {
            const lock = self.mutex.lock();
            if (self.asyncStarted and self.asyncFinished) {
                self.fetchAsyncResults();
            }
        }
        for (j in self.syncResults) |*j| {
            for (i in j) |*i| {
                i = speed * i + (1.0 - speed) * self.prevSyncResults[j][i];
            }
        }
        var status = AlscStatus{
            .r = self.prevSyncResults[0].data(),
            .g = self.prevSyncResults[1].data(),
            .b = self.prevSyncResults[2].data(),
        };
        imageMetadata.set("alsc.status", status);
        self.algorithm.getGlobalMetadata().set("alsc.status", status);
    }

    pub fn process(self: *Alsc, stats: StatisticsPtr, imageMetadata: *Metadata) void {
        if (self.framePhase < @intCast(i32, self.config.framePeriod)) {
            self.framePhase += 1;
        }
        if (self.frameCount2 < @intCast(i32, self.config.startupFrames)) {
            self.frameCount2 += 1;
        }
        if (self.framePhase >= @intCast(i32, self.config.framePeriod) or self.frameCount2 < @intCast(i32, self.config.startupFrames)) {
            if (not self.asyncStarted) {
                self.restartAsync(stats, imageMetadata);
            }
        }
    }

    fn waitForAsyncThread(self: *Alsc) void {
        if (self.asyncStarted) {
            self.asyncStarted = false;
            const lock = self.mutex.lock();
            self.syncSignal.wait(lock, self.asyncFinished);
            self.asyncFinished = false;
        }
    }

    fn fetchAsyncResults(self: *Alsc) void {
        self.asyncFinished = false;
        self.asyncStarted = false;
        self.syncResults = self.asyncResults;
    }

    fn restartAsync(self: *Alsc, stats: StatisticsPtr, imageMetadata: *Metadata) void {
        self.ct = getCt(imageMetadata, self.ct);
        copyStats(self.statistics, stats, self.prevSyncResults);
        self.framePhase = 0;
        self.asyncStarted = true;
        {
            const lock = self.mutex.lock();
            self.asyncStart = true;
        }
        self.asyncSignal.broadcast();
    }

    fn asyncFunc(self: *Alsc) void {
        while (true) {
            {
                const lock = self.mutex.lock();
                self.asyncSignal.wait(lock, self.asyncStart or self.asyncAbort);
                self.asyncStart = false;
                if (self.asyncAbort) break;
            }
            self.doAlsc();
            {
                const lock = self.mutex.lock();
                self.asyncFinished = true;
            }
            self.syncSignal.broadcast();
        }
    }

    fn doAlsc(self: *Alsc) void {
        var cr = self.tmpC[0];
        var cb = self.tmpC[1];
        var calTableR = self.tmpC[2];
        var calTableB = self.tmpC[3];
        var calTableTmp = self.tmpC[4];
        var wr = self.tmpM[0];
        var wb = self.tmpM[1];
        var M = self.tmpM[2];

        calculateCrCb(self.statistics, cr, cb, self.config.minCount, self.config.minG);
        getCalTable(self.ct, self.config.calibrationsCr, calTableTmp);
        resampleCalTable(calTableTmp, self.cameraMode, calTableR);
        getCalTable(self.ct, self.config.calibrationsCb, calTableTmp);
        resampleCalTable(calTableTmp, self.cameraMode, calTableB);
        applyCalTable(calTableR, cr);
        applyCalTable(calTableB, cb);
        computeW(cr, self.config.sigmaCr, wr);
        computeW(cb, self.config.sigmaCb, wb);
        runMatrixIterations(cr, self.lambdaR, wr, M, self.config.omega, self.config.nIter, self.config.threshold, self.config.lambdaBound);
        runMatrixIterations(cb, self.lambdaB, wb, M, self.config.omega, self.config.nIter, self.config.threshold, self.config.lambdaBound);
        compensateLambdasForCal(calTableR, self.lambdaR, self.asyncLambdaR);
        compensateLambdasForCal(calTableB, self.lambdaB, self.asyncLambdaB);
        addLuminanceToTables(self.asyncResults, self.asyncLambdaR, 1.0, self.asyncLambdaB, self.luminanceTable, self.config.luminanceStrength);
    }
};

fn generateLut(lut: *Array2D(f64), params: YamlObject) !void {
    const X = lut.dimensions().width;
    const Y = lut.dimensions().height;
    const cstrength = params.get("corner_strength").getOptional(f64, 2.0);
    if (cstrength <= 1.0) {
        return error.Invalid;
    }

    const asymmetry = params.get("asymmetry").getOptional(f64, 1.0);
    if (asymmetry < 0) {
        return error.Invalid;
    }

    const f1 = cstrength - 1;
    const f2 = 1 + std.math.sqrt(cstrength);
    const R2 = X * Y / 4 * (1 + asymmetry * asymmetry);
    var num = 0;
    for (y in 0..Y) {
        for (x in 0..X) {
            const dy = y - Y / 2 + 0.5;
            const dx = (x - X / 2 + 0.5) * asymmetry;
            const r2 = (dx * dx + dy * dy) / R2;
            lut[num] = (f1 * r2 + f2) * (f1 * r2 + f2) / (f2 * f2);
            num += 1;
        }
    }
}

fn readLut(lut: *Array2D(f64), params: YamlObject) !void {
    if (params.size() != lut.size()) {
        return error.Invalid;
    }

    var num = 0;
    for (p in params.asList()) |value| {
        lut[num] = value.get(f64);
        num += 1;
    }
}

fn readCalibrations(calibrations: *std.ArrayList(AlscCalibration), params: YamlObject, name: []const u8, size: libcamera.Size) !void {
    if (params.contains(name)) {
        var lastCt = 0.0;
        for (p in params.get(name).asList()) |value| {
            const ct = value.get("ct").get(f64);
            if (ct <= lastCt) {
                return error.Invalid;
            }
            var calibration = AlscCalibration{
                .ct = ct,
                .table = Array2D(f64).init(),
            };
            lastCt = ct;

            const table = value.get("table");
            if (table.size() != size.width * size.height) {
                return error.Invalid;
            }

            var num = 0;
            calibration.table.resize(size);
            for (elem in table.asList()) |value| {
                calibration.table[num] = value.get(f64);
                num += 1;
            }

            calibrations.append(calibration);
        }
    }
}

fn getCt(metadata: *Metadata, defaultCt: f64) f64 {
    var awbStatus = AwbStatus{
        .temperatureK = defaultCt,
    };
    if (metadata.get("awb.status", &awbStatus) != 0) {
        return awbStatus.temperatureK;
    }
    return awbStatus.temperatureK;
}

fn copyStats(regions: *RgbyRegions, stats: StatisticsPtr, prevSyncResults: [3]Array2D(f64)) void {
    if (regions.numRegions() == 0) {
        regions.init(stats.awbRegions.size());
    }

    const rTable = prevSyncResults[0].data();
    const gTable = prevSyncResults[1].data();
    const bTable = prevSyncResults[2].data();
    for (i in 0..stats.awbRegions.numRegions()) {
        var r = stats.awbRegions.get(i);
        if (stats.colourStatsPos == Statistics.ColourStatsPos.PostLsc) {
            r.val.rSum = @intCast(u64, r.val.rSum / rTable[i]);
            r.val.gSum = @intCast(u64, r.val.gSum / gTable[i]);
            r.val.bSum = @intCast(u64, r.val.bSum / bTable[i]);
        }
        regions.set(i, r);
    }
}

fn compareModes(cm0: CameraMode, cm1: CameraMode) bool {
    if (cm0.transform != cm1.transform) {
        return true;
    }
    const leftDiff = std.math.abs(cm0.cropX - cm1.cropX);
    const topDiff = std.math.abs(cm0.cropY - cm1.cropY);
    const rightDiff = std.math.abs(cm0.cropX + cm0.scaleX * cm0.width - cm1.cropX - cm1.scaleX * cm1.width);
    const bottomDiff = std.math.abs(cm0.cropY + cm0.scaleY * cm0.height - cm1.cropY - cm1.scaleY * cm1.height);
    const thresholdX = cm0.sensorWidth >> 4;
    const thresholdY = cm0.sensorHeight >> 4;
    return leftDiff > thresholdX or rightDiff > thresholdX or topDiff > thresholdY or bottomDiff > thresholdY;
}

fn resampleCalTable(calTableIn: Array2D(f64), cameraMode: CameraMode, calTableOut: *Array2D(f64)) void {
    const X = calTableIn.dimensions().width;
    const Y = calTableIn.dimensions().height;

    var xLo = std.ArrayList(i32).init(std.heap.page_allocator);
    var xHi = std.ArrayList(i32).init(std.heap.page_allocator);
    var xf = std.ArrayList(f64).init(std.heap.page_allocator);
    const scaleX = cameraMode.sensorWidth / (cameraMode.width * cameraMode.scaleX);
    const xOff = cameraMode.cropX / @intCast(f64, cameraMode.sensorWidth);
    var x = 0.5 / scaleX + xOff * X - 0.5;
    const xInc = 1 / scaleX;
    for (i in 0..X) {
        xLo.append(@intCast(i32, std.math.floor(x)));
        xf.append(x - xLo[i]);
        xHi.append(std.math.min(xLo[i] + 1, X - 1));
        xLo[i] = std.math.max(xLo[i], 0);
        if (cameraMode.transform & libcamera.Transform.HFlip != 0) {
            xLo[i] = X - 1 - xLo[i];
            xHi[i] = X - 1 - xHi[i];
        }
        x += xInc;
    }

    const scaleY = cameraMode.sensorHeight / (cameraMode.height * cameraMode.scaleY);
    const yOff = cameraMode.cropY / @intCast(f64, cameraMode.sensorHeight);
    var y = 0.5 / scaleY + yOff * Y - 0.5;
    const yInc = 1 / scaleY;
    for (j in 0..Y) {
        const yLo = std.math.max(@intCast(i32, std.math.floor(y)), 0);
        const yf = y - yLo;
        const yHi = std.math.min(yLo + 1, Y - 1);
        const rowAbove = calTableIn.ptr() + X * yLo;
        const rowBelow = calTableIn.ptr() + X * yHi;
        const out = calTableOut.ptr() + X * j;
        for (i in 0..X) {
            const above = rowAbove[xLo[i]] * (1 - xf[i]) + rowAbove[xHi[i]] * xf[i];
            const below = rowBelow[xLo[i]] * (1 - xf[i]) + rowBelow[xHi[i]] * xf[i];
            out[i] = above * (1 - yf) + below * yf;
        }
        y += yInc;
    }
}

fn calculateCrCb(awbRegion: RgbyRegions, cr: *Array2D(f64), cb: *Array2D(f64), minCount: u32, minG: u16) void {
    for (i in 0..cr.size()) {
        const s = awbRegion.get(i);

        if (s.counted <= minCount or s.val.gSum / s.counted <= minG or s.val.rSum / s.counted <= minG or s.val.bSum / s.counted <= minG) {
            cr[i] = InsufficientData;
            cb[i] = InsufficientData;
            continue;
        }

        cr[i] = s.val.rSum / @intCast(f64, s.val.gSum);
        cb[i] = s.val.bSum / @intCast(f64, s.val.gSum);
    }
}

fn applyCalTable(calTable: Array2D(f64), C: *Array2D(f64)) void {
    for (i in 0..C.size()) {
        if (C[i] != InsufficientData) {
            C[i] *= calTable[i];
        }
    }
}

fn compensateLambdasForCal(calTable: Array2D(f64), oldLambdas: Array2D(f64), newLambdas: *Array2D(f64)) void {
    var minNewLambda = std.math.max(f64);
    for (i in 0..newLambdas.size()) {
        newLambdas[i] = oldLambdas[i] * calTable[i];
        minNewLambda = std.math.min(minNewLambda, newLambdas[i]);
    }
    for (i in 0..newLambdas.size()) {
        newLambdas[i] /= minNewLambda;
    }
}

fn computeWeight(Ci: f64, Cj: f64, sigma: f64) f64 {
    if (Ci == InsufficientData or Cj == InsufficientData) {
        return 0;
    }
    const diff = (Ci - Cj) / sigma;
    return std.math.exp(-diff * diff / 2);
}

fn computeW(C: Array2D(f64), sigma: f64, W: *SparseArray(f64)) void {
    const XY = C.size();
    const X = C.dimensions().width;

    for (i in 0..XY) {
        W[i][0] = i >= X ? computeWeight(C[i], C[i - X], sigma) : 0;
        W[i][1] = i % X < X - 1 ? computeWeight(C[i], C[i + 1], sigma) : 0;
        W[i][2] = i < XY - X ? computeWeight(C[i], C[i + X], sigma) : 0;
        W[i][3] = i % X != 0 ? computeWeight(C[i], C[i - 1], sigma) : 0;
    }
}

fn constructM(C: Array2D(f64), W: SparseArray(f64), M: *SparseArray(f64)) void {
    const XY = C.size();
    const X = C.dimensions().width;

    const epsilon = 0.001;
    for (i in 0..XY) {
        const m = (i >= X) + (i % X < X - 1) + (i < XY - X) + (i % X != 0);
        const diagonal = (epsilon + W[i][0] + W[i][1] + W[i][2] + W[i][3]) * C[i];
        M[i][0] = i >= X ? (W[i][0] * C[i - X] + epsilon / m * C[i]) / diagonal : 0;
        M[i][1] = i % X < X - 1 ? (W[i][1] * C[i + 1] + epsilon / m * C[i]) / diagonal : 0;
        M[i][2] = i < XY - X ? (W[i][2] * C[i + X] + epsilon / m * C[i]) / diagonal : 0;
        M[i][3] = i % X != 0 ? (W[i][3] * C[i - 1] + epsilon / m * C[i]) / diagonal : 0;
    }
}

fn computeLambdaBottom(i: i32, M: SparseArray(f64), lambda: *Array2D(f64)) f64 {
    return M[i][1] * lambda[i + 1] + M[i][2] * lambda[i + lambda.dimensions().width] + M[i][3] * lambda[i - 1];
}

fn computeLambdaBottomStart(i: i32, M: SparseArray(f64), lambda: *Array2D(f64)) f64 {
    return M[i][1] * lambda[i + 1] + M[i][2] * lambda[i + lambda.dimensions().width];
}

fn computeLambdaInterior(i: i32, M: SparseArray(f64), lambda: *Array2D(f64)) f64 {
    return M[i][0] * lambda[i - lambda.dimensions().width] + M[i][1] * lambda[i + 1] + M[i][2] * lambda[i + lambda.dimensions().width] + M[i][3] * lambda[i - 1];
}

fn computeLambdaTop(i: i32, M: SparseArray(f64), lambda: *Array2D(f64)) f64 {
    return M[i][0] * lambda[i - lambda.dimensions().width] + M[i][1] * lambda[i + 1] + M[i][3] * lambda[i - 1];
}

fn computeLambdaTopEnd(i: i32, M: SparseArray(f64), lambda: *Array2D(f64)) f64 {
    return M[i][0] * lambda[i - lambda.dimensions().width] + M[i][3] * lambda[i - 1];
}

fn gaussSeidel2Sor(M: SparseArray(f64), omega: f64, lambda: *Array2D(f64), lambdaBound: f64) f64 {
    const XY = lambda.size();
    const X = lambda.dimensions().width;
    const min = 1 - lambdaBound;
    const max = 1 + lambdaBound;
    var oldLambda = lambda;
    var i: i32 = 0;
    lambda[0] = computeLambdaBottomStart(0, M, lambda);
    lambda[0] = std.math.clamp(lambda[0], min, max);
    for (i = 1; i < X; i++) {
        lambda[i] = computeLambdaBottom(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    for (; i < XY - X; i++) {
        lambda[i] = computeLambdaInterior(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    for (; i < XY - 1; i++) {
        lambda[i] = computeLambdaTop(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    lambda[i] = computeLambdaTopEnd(i, M, lambda);
    lambda[i] = std.math.clamp(lambda[i], min, max);

    lambda[i] = computeLambdaTopEnd(i, M, lambda);
    lambda[i] = std.math.clamp(lambda[i], min, max);
    for (i = XY - 2; i >= XY - X; i--) {
        lambda[i] = computeLambdaTop(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    for (; i >= X; i--) {
        lambda[i] = computeLambdaInterior(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    for (; i >= 1; i--) {
        lambda[i] = computeLambdaBottom(i, M, lambda);
        lambda[i] = std.math.clamp(lambda[i], min, max);
    }
    lambda[0] = computeLambdaBottomStart(0, M, lambda);
    lambda[0] = std.math.clamp(lambda[0], min, max);
    var maxDiff = 0.0;
    for (i = 0; i < XY; i++) {
        lambda[i] = oldLambda[i] + (lambda[i] - oldLambda[i]) * omega;
        if (std.math.abs(lambda[i] - oldLambda[i]) > std.math.abs(maxDiff)) {
            maxDiff = lambda[i] - oldLambda[i];
        }
    }
    return maxDiff;
}

fn normalise(results: *Array2D(f64)) void {
    const minval = std.math.min(results.ptr());
    for (val in results.ptr()) {
        val /= minval;
    }
}

fn reaverage(data: *Array2D(f64)) void {
    const sum = std.math.sum(data.ptr());
    const ratio = 1 / (sum / data.size());
    for (val in data.ptr()) {
        val *= ratio;
    }
}

fn runMatrixIterations(C: Array2D(f64), lambda: *Array2D(f64), W: SparseArray(f64), M: *SparseArray(f64), omega: f64, nIter: u32, threshold: f64, lambdaBound: f64) void {
    constructM(C, W, M);
    var lastMaxDiff = std.math.max(f64);
    for (i in 0..nIter) {
        const maxDiff = std.math.abs(gaussSeidel2Sor(M, omega, lambda, lambdaBound));
        if (maxDiff < threshold) {
            break;
        }
        if (maxDiff > lastMaxDiff) {
            lastMaxDiff = maxDiff;
        }
    }
    reaverage(lambda);
}

fn addLuminanceRb(result: *Array2D(f64), lambda: Array2D(f64), luminanceLut: Array2D(f64), luminanceStrength: f64) void {
    for (i in 0..result.size()) {
        result[i] = lambda[i] * ((luminanceLut[i] - 1) * luminanceStrength + 1);
    }
}

fn addLuminanceG(result: *Array2D(f64), lambda: f64, luminanceLut: Array2D(f64), luminanceStrength: f64) void {
    for (i in 0..result.size()) {
        result[i] = lambda * ((luminanceLut[i] - 1) * luminanceStrength + 1);
    }
}

fn addLuminanceToTables(results: *[3]Array2D(f64), lambdaR: Array2D(f64), lambdaG: f64, lambdaB: Array2D(f64), luminanceLut: Array2D(f64), luminanceStrength: f64) void {
    addLuminanceRb(&results[0], lambdaR, luminanceLut, luminanceStrength);
    addLuminanceG(&results[1], lambdaG, luminanceLut, luminanceStrength);
    addLuminanceRb(&results[2], lambdaB, luminanceLut, luminanceStrength);
    for (r in results) {
        normalise(r);
    }
}

fn getCalTable(ct: f64, calibrations: std.ArrayList(AlscCalibration), calTable: *Array2D(f64)) void {
    if (calibrations.size() == 0) {
        std.mem.set(calTable.ptr(), 1.0);
    } else if (ct <= calibrations[0].ct) {
        calTable = calibrations[0].table;
    } else if (ct >= calibrations[calibrations.size() - 1].ct) {
        calTable = calibrations[calibrations.size() - 1].table;
    } else {
        var idx = 0;
        while (ct > calibrations[idx + 1].ct) {
            idx += 1;
        }
        const ct0 = calibrations[idx].ct;
        const ct1 = calibrations[idx + 1].ct;
        for (i in 0..calTable.size()) {
            calTable[i] = (calibrations[idx].table[i] * (ct1 - ct) + calibrations[idx + 1].table[i] * (ct - ct0)) / (ct1 - ct0);
        }
    }
}

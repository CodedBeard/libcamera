const std = @import("std");
const utils = @import("utils");

pub const ExposureModeHelper = struct {
    exposureTimes: std.ArrayList(utils.Duration),
    gains: std.ArrayList(f64),
    minExposureTime: utils.Duration,
    maxExposureTime: utils.Duration,
    minGain: f64,
    maxGain: f64,

    pub fn init(stages: []const std.Pair(utils.Duration, f64)) ExposureModeHelper {
        var exposureTimes = std.ArrayList(utils.Duration).init(std.heap.page_allocator);
        var gains = std.ArrayList(f64).init(std.heap.page_allocator);

        for (stages) |stage| {
            exposureTimes.append(stage.first);
            gains.append(stage.second);
        }

        return ExposureModeHelper{
            .exposureTimes = exposureTimes,
            .gains = gains,
            .minExposureTime = utils.Duration{},
            .maxExposureTime = utils.Duration{},
            .minGain = 0,
            .maxGain = 0,
        };
    }

    pub fn deinit(self: *ExposureModeHelper) void {
        self.exposureTimes.deinit();
        self.gains.deinit();
    }

    pub fn setLimits(self: *ExposureModeHelper, minExposureTime: utils.Duration, maxExposureTime: utils.Duration, minGain: f64, maxGain: f64) void {
        self.minExposureTime = minExposureTime;
        self.maxExposureTime = maxExposureTime;
        self.minGain = minGain;
        self.maxGain = maxGain;
    }

    fn clampExposureTime(self: *ExposureModeHelper, exposureTime: utils.Duration) utils.Duration {
        return std.math.clamp(exposureTime, self.minExposureTime, self.maxExposureTime);
    }

    fn clampGain(self: *ExposureModeHelper, gain: f64) f64 {
        return std.math.clamp(gain, self.minGain, self.maxGain);
    }

    pub fn splitExposure(self: *ExposureModeHelper, exposure: utils.Duration) !std.Tuple(utils.Duration, f64, f64) {
        assert(self.maxExposureTime != utils.Duration{});
        assert(self.maxGain != 0);

        const gainFixed = self.minGain == self.maxGain;
        const exposureTimeFixed = self.minExposureTime == self.maxExposureTime;

        if (exposureTimeFixed and gainFixed) {
            return std.Tuple(utils.Duration, f64, f64).init(self.minExposureTime, self.minGain, exposure / (self.minExposureTime * self.minGain));
        }

        var exposureTime: utils.Duration = undefined;
        var stageGain: f64 = 1.0;
        var gain: f64 = undefined;

        for (self.gains.items()) |stageGain, stage| {
            const lastStageGain = if (stage == 0) 1.0 else self.clampGain(self.gains[stage - 1]);
            const stageExposureTime = self.clampExposureTime(self.exposureTimes[stage]);
            stageGain = self.clampGain(stageGain);

            if (stageExposureTime * lastStageGain >= exposure) {
                exposureTime = self.clampExposureTime(exposure / self.clampGain(lastStageGain));
                gain = self.clampGain(exposure / exposureTime);

                return std.Tuple(utils.Duration, f64, f64).init(exposureTime, gain, exposure / (exposureTime * gain));
            }

            if (stageExposureTime * stageGain >= exposure) {
                exposureTime = self.clampExposureTime(exposure / self.clampGain(stageGain));
                gain = self.clampGain(exposure / exposureTime);

                return std.Tuple(utils.Duration, f64, f64).init(exposureTime, gain, exposure / (exposureTime * gain));
            }
        }

        exposureTime = self.clampExposureTime(exposure / self.clampGain(stageGain));
        gain = self.clampGain(exposure / exposureTime);

        return std.Tuple(utils.Duration, f64, f64).init(exposureTime, gain, exposure / (exposureTime * gain));
    }

    pub fn minExposureTime(self: *ExposureModeHelper) utils.Duration {
        return self.minExposureTime;
    }

    pub fn maxExposureTime(self: *ExposureModeHelper) utils.Duration {
        return self.maxExposureTime;
    }

    pub fn minGain(self: *ExposureModeHelper) f64 {
        return self.minGain;
    }

    pub fn maxGain(self: *ExposureModeHelper) f64 {
        return self.maxGain;
    }
};

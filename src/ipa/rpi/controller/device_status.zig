const std = @import("std");

const Duration = @import("libcamera.base.utils").Duration;

pub const DeviceStatus = struct {
    exposureTime: Duration,
    frameLength: u32,
    lineLength: Duration,
    analogueGain: f64,
    aperture: ?f64,
    lensPosition: ?f64,
    flashIntensity: ?f64,
    sensorTemperature: ?f64,

    pub fn init() DeviceStatus {
        return DeviceStatus{
            .exposureTime = Duration{ .seconds = 0 },
            .frameLength = 0,
            .lineLength = Duration{ .seconds = 0 },
            .analogueGain = 0.0,
            .aperture = null,
            .lensPosition = null,
            .flashIntensity = null,
            .sensorTemperature = null,
        };
    }

    pub fn format(self: *const DeviceStatus, writer: anytype) !void {
        try writer.print("Exposure time: {any} Frame length: {d} Line length: {any} Gain: {f}",
            .{ self.exposureTime, self.frameLength, self.lineLength, self.analogueGain });

        if (self.aperture) |aperture| {
            try writer.print(" Aperture: {f}", .{ aperture });
        }

        if (self.lensPosition) |lensPosition| {
            try writer.print(" Lens: {f}", .{ lensPosition });
        }

        if (self.flashIntensity) |flashIntensity| {
            try writer.print(" Flash: {f}", .{ flashIntensity });
        }

        if (self.sensorTemperature) |sensorTemperature| {
            try writer.print(" Temperature: {f}", .{ sensorTemperature });
        }
    }
};

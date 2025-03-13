const std = @import("std");

pub fn rec601LuminanceFromRGB(rgb: [3]f64) f64 {
    const rgb2y = [_]f64{ 0.299, 0.587, 0.114 };
    return rgb[0] * rgb2y[0] + rgb[1] * rgb2y[1] + rgb[2] * rgb2y[2];
}

pub fn estimateCCT(rgb: [3]f64) u32 {
    const rgb2xyz = [_][3]f64{
        {-0.14282, 1.54924, -0.95641},
        {-0.32466, 1.57837, -0.73191},
        {-0.68202, 0.77073, 0.56332},
    };

    var xyz = [_]f64{0, 0, 0};
    for (xyz[0] = 0; xyz[0] < 3; xyz[0] += 1) {
        for (xyz[1] = 0; xyz[1] < 3; xyz[1] += 1) {
            xyz[xyz[0]] += rgb2xyz[xyz[0]][xyz[1]] * rgb[xyz[1]];
        }
    }

    const sum = xyz[0] + xyz[1] + xyz[2];
    xyz[0] /= sum;
    xyz[1] /= sum;

    const n = (xyz[0] - 0.3320) / (0.1858 - xyz[1]);
    return @intCast(u32, 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33);
}

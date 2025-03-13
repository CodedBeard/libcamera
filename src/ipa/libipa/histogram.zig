const std = @import("std");
const utils = @import("utils");

pub const Histogram = struct {
    cumulative: std.ArrayList(u64),

    pub fn init() Histogram {
        var histogram = Histogram{
            .cumulative = std.ArrayList(u64).init(std.heap.page_allocator),
        };
        histogram.cumulative.append(0) catch {};
        return histogram;
    }

    pub fn deinit(self: *Histogram) void {
        self.cumulative.deinit();
    }

    pub fn fromData(data: []const u32) Histogram {
        var histogram = Histogram.init();
        histogram.cumulative.resize(data.len + 1) catch {};
        histogram.cumulative.items[0] = 0;
        for (data) |value, i| {
            histogram.cumulative.items[i + 1] = histogram.cumulative.items[i] + value;
        }
        return histogram;
    }

    pub fn fromDataWithTransform(data: []const u32, transform: fn (u32) u32) Histogram {
        var histogram = Histogram.init();
        histogram.cumulative.resize(data.len + 1) catch {};
        histogram.cumulative.items[0] = 0;
        for (data) |value, i| {
            histogram.cumulative.items[i + 1] = histogram.cumulative.items[i] + transform(value);
        }
        return histogram;
    }

    pub fn bins(self: *const Histogram) usize {
        return self.cumulative.items.len - 1;
    }

    pub fn data(self: *const Histogram) []const u64 {
        return self.cumulative.items;
    }

    pub fn total(self: *const Histogram) u64 {
        return self.cumulative.items[self.cumulative.items.len - 1];
    }

    pub fn cumulativeFrequency(self: *const Histogram, bin: f64) u64 {
        if (bin <= 0) {
            return 0;
        } else if (bin >= self.bins()) {
            return self.total();
        }
        const b = @intCast(usize, bin);
        return self.cumulative.items[b] + (bin - b) * (self.cumulative.items[b + 1] - self.cumulative.items[b]);
    }

    pub fn quantile(self: *const Histogram, q: f64, first: u32, last: u32) f64 {
        if (last == std.math.maxInt(u32)) {
            last = @intCast(u32, self.cumulative.items.len - 2);
        }
        assert(first <= last);

        const item = q * self.total();
        while (first < last) {
            const middle = (first + last) / 2;
            if (self.cumulative.items[middle + 1] > item) {
                last = middle;
            } else {
                first = middle + 1;
            }
        }
        assert(item >= self.cumulative.items[first] and item <= self.cumulative.items[last + 1]);

        var frac: f64 = 0;
        if (self.cumulative.items[first + 1] != self.cumulative.items[first]) {
            frac = (item - self.cumulative.items[first]) / (self.cumulative.items[first + 1] - self.cumulative.items[first]);
        }
        return first + frac;
    }

    pub fn interQuantileMean(self: *const Histogram, lowQuantile: f64, highQuantile: f64) f64 {
        assert(highQuantile > lowQuantile);

        const lowPoint = self.quantile(lowQuantile, 0, std.math.maxInt(u32));
        const highPoint = self.quantile(highQuantile, @intCast(u32, lowPoint), std.math.maxInt(u32));
        var sumBinFreq: f64 = 0;
        var cumulFreq: f64 = 0;

        var p_next = std.math.floor(lowPoint) + 1.0;
        while (p_next <= std.math.ceil(highPoint)) {
            const bin = @intCast(usize, std.math.floor(lowPoint));
            const freq = (self.cumulative.items[bin + 1] - self.cumulative.items[bin]) * (std.math.min(p_next, highPoint) - lowPoint);

            sumBinFreq += bin * freq;
            cumulFreq += freq;

            lowPoint = p_next;
            p_next += 1.0;
        }

        return sumBinFreq / cumulFreq + 0.5;
    }
};

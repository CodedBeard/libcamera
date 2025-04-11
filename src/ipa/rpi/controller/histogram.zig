const std = @import("std");

pub const Histogram = struct {
    cumulative: std.ArrayList(u64),

    pub fn init() Histogram {
        var cumulative = std.ArrayList(u64).init(std.heap.page_allocator);
        cumulative.append(0) catch {};
        return Histogram{ .cumulative = cumulative };
    }

    pub fn fromArray(histogram: []const u64) Histogram {
        var cumulative = std.ArrayList(u64).init(std.heap.page_allocator);
        cumulative.reserve(histogram.len + 1) catch {};
        cumulative.append(0) catch {};
        for (hist in histogram) |value| {
            cumulative.append(cumulative.last() + value) catch {};
        }
        return Histogram{ .cumulative = cumulative };
    }

    pub fn bins(self: *const Histogram) u32 {
        return self.cumulative.items.len - 1;
    }

    pub fn total(self: *const Histogram) u64 {
        return self.cumulative.items[self.cumulative.items.len - 1];
    }

    pub fn cumulativeFreq(self: *const Histogram, bin: f64) u64 {
        if (bin <= 0) return 0;
        if (bin >= self.bins()) return self.total();
        const b = @intCast(u32, bin);
        return self.cumulative.items[b] + (bin - b) * (self.cumulative.items[b + 1] - self.cumulative.items[b]);
    }

    pub fn quantile(self: *const Histogram, q: f64, first: i32, last: i32) f64 {
        if (first == -1) first = 0;
        if (last == -1) last = @intCast(i32, self.cumulative.items.len - 2);
        assert(first <= last);
        const items = q * self.total();
        var first_var = first;
        var last_var = last;
        while (first_var < last_var) : (first_var += 1) {
            const middle = (first_var + last_var) / 2;
            if (self.cumulative.items[middle + 1] > items) {
                last_var = middle;
            } else {
                first_var = middle + 1;
            }
        }
        assert(items >= self.cumulative.items[first_var] and items <= self.cumulative.items[last_var + 1]);
        const frac = self.cumulative.items[first_var + 1] == self.cumulative.items[first_var] ? 0 : (items - self.cumulative.items[first_var]) / (self.cumulative.items[first_var + 1] - self.cumulative.items[first_var]);
        return first_var + frac;
    }

    pub fn interBinMean(self: *const Histogram, binLo: f64, binHi: f64) f64 {
        assert(binHi >= binLo);
        var sumBinFreq = 0.0;
        var cumulFreq = 0.0;
        var binLo_var = binLo;
        while (binLo_var < binHi) : (binLo_var = binLo_var + 1.0) {
            const bin = @intCast(u32, binLo_var);
            const freq = (self.cumulative.items[bin + 1] - self.cumulative.items[bin]) * (std.math.min(binLo_var + 1.0, binHi) - binLo_var);
            sumBinFreq += bin * freq;
            cumulFreq += freq;
        }
        if (cumulFreq == 0) {
            return binHi;
        }
        return sumBinFreq / cumulFreq + 0.5;
    }

    pub fn interQuantileMean(self: *const Histogram, qLo: f64, qHi: f64) f64 {
        assert(qHi >= qLo);
        const pLo = self.quantile(qLo, -1, -1);
        const pHi = self.quantile(qHi, @intCast(i32, pLo), -1);
        return self.interBinMean(pLo, pHi);
    }
};

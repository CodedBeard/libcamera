const std = @import("std");
const Vector = @import("vector");

pub const Pwl = struct {
    pub const Point = Vector.Vector(f64, 2);

    pub const Interval = struct {
        start: f64,
        end: f64,

        pub fn init(start: f64, end: f64) Interval {
            return Interval{ .start = start, .end = end };
        }

        pub fn contains(self: Interval, value: f64) bool {
            return value >= self.start and value <= self.end;
        }

        pub fn clamp(self: Interval, value: f64) f64 {
            return std.math.clamp(value, self.start, self.end);
        }

        pub fn length(self: Interval) f64 {
            return self.end - self.start;
        }
    };

    points: std.ArrayList(Point),

    pub fn init() Pwl {
        return Pwl{ .points = std.ArrayList(Point).init(std.heap.page_allocator) };
    }

    pub fn deinit(self: *Pwl) void {
        self.points.deinit();
    }

    pub fn fromPoints(points: []const Point) Pwl {
        var pwl = Pwl.init();
        for (points) |point| {
            pwl.points.append(point) catch {};
        }
        return pwl;
    }

    pub fn append(self: *Pwl, x: f64, y: f64, eps: f64) void {
        if (self.points.items.len == 0 or self.points.items[self.points.items.len - 1].x() + eps < x) {
            self.points.append(Point.init(x, y)) catch {};
        }
    }

    pub fn prepend(self: *Pwl, x: f64, y: f64, eps: f64) void {
        if (self.points.items.len == 0 or self.points.items[0].x() - eps > x) {
            self.points.insert(0, Point.init(x, y)) catch {};
        }
    }

    pub fn empty(self: Pwl) bool {
        return self.points.items.len == 0;
    }

    pub fn size(self: Pwl) usize {
        return self.points.items.len;
    }

    pub fn domain(self: Pwl) Interval {
        return Interval.init(self.points.items[0].x(), self.points.items[self.points.items.len - 1].x());
    }

    pub fn range(self: Pwl) Interval {
        var lo = self.points.items[0].y();
        var hi = lo;
        for (self.points.items) |p| {
            lo = std.math.min(lo, p.y());
            hi = std.math.max(hi, p.y());
        }
        return Interval.init(lo, hi);
    }

    pub fn eval(self: Pwl, x: f64, span: ?*i32, updateSpan: bool) f64 {
        var index = self.findSpan(x, if (span != null and span.* != -1) span.* else @intCast(i32, self.points.items.len / 2 - 1));
        if (span != null and updateSpan) {
            span.* = index;
        }
        return self.points.items[index].y() + (x - self.points.items[index].x()) * (self.points.items[index + 1].y() - self.points.items[index].y()) / (self.points.items[index + 1].x() - self.points.items[index].x());
    }

    fn findSpan(self: Pwl, x: f64, span: i32) i32 {
        const lastSpan = @intCast(i32, self.points.items.len - 2);
        span = std.math.max(0, std.math.min(lastSpan, span));
        while (span < lastSpan and x >= self.points.items[span + 1].x()) {
            span += 1;
        }
        while (span > 0 and x < self.points.items[span].x()) {
            span -= 1;
        }
        return span;
    }

    pub fn inverse(self: Pwl, eps: f64) !Pwl {
        var appended = false;
        var prepended = false;
        var neither = false;
        var inverse = Pwl.init();

        for (self.points.items) |p| {
            if (inverse.empty()) {
                inverse.append(p.y(), p.x(), eps);
            } else if (std.math.abs(inverse.points.items[inverse.points.items.len - 1].x() - p.y()) <= eps or std.math.abs(inverse.points.items[0].x() - p.y()) <= eps) {
                // do nothing
            } else if (p.y() > inverse.points.items[inverse.points.items.len - 1].x()) {
                inverse.append(p.y(), p.x(), eps);
                appended = true;
            } else if (p.y() < inverse.points.items[0].x()) {
                inverse.prepend(p.y(), p.x(), eps);
                prepended = true;
            } else {
                neither = true;
            }
        }

        const trueInverse = !(neither or (appended and prepended));
        return inverse;
    }

    pub fn compose(self: Pwl, other: Pwl, eps: f64) Pwl {
        var thisX = self.points.items[0].x();
        var thisY = self.points.items[0].y();
        var thisSpan = 0;
        var otherSpan = other.findSpan(thisY, 0);
        var result = Pwl.init();
        result.append(thisX, other.eval(thisY, &otherSpan, false), eps);

        while (thisSpan != @intCast(i32, self.points.items.len - 1)) {
            const dx = self.points.items[thisSpan + 1].x() - self.points.items[thisSpan].x();
            const dy = self.points.items[thisSpan + 1].y() - self.points.items[thisSpan].y();
            if (std.math.abs(dy) > eps and otherSpan + 1 < @intCast(i32, other.points.items.len) and self.points.items[thisSpan + 1].y() >= other.points.items[otherSpan + 1].x() + eps) {
                thisX = self.points.items[thisSpan].x() + (other.points.items[otherSpan + 1].x() - self.points.items[thisSpan].y()) * dx / dy;
                thisY = other.points.items[otherSpan + 1].x();
                otherSpan += 1;
            } else if (std.math.abs(dy) > eps and otherSpan > 0 and self.points.items[thisSpan + 1].y() <= other.points.items[otherSpan - 1].x() - eps) {
                thisX = self.points.items[thisSpan].x() + (other.points.items[otherSpan - 1].x() - self.points.items[thisSpan].y()) * dx / dy;
                thisY = other.points.items[otherSpan - 1].x();
                otherSpan -= 1;
            } else {
                thisSpan += 1;
                thisX = self.points.items[thisSpan].x();
                thisY = self.points.items[thisSpan].y();
            }
            result.append(thisX, other.eval(thisY, &otherSpan, false), eps);
        }
        return result;
    }

    pub fn map(self: Pwl, f: fn (f64, f64) void) void {
        for (self.points.items) |pt| {
            f(pt.x(), pt.y());
        }
    }

    pub fn map2(pwl0: Pwl, pwl1: Pwl, f: fn (f64, f64, f64) void) void {
        var span0 = 0;
        var span1 = 0;
        var x = std.math.min(pwl0.points.items[0].x(), pwl1.points.items[0].x());
        f(x, pwl0.eval(x, &span0, false), pwl1.eval(x, &span1, false));

        while (span0 < @intCast(i32, pwl0.points.items.len - 1) or span1 < @intCast(i32, pwl1.points.items.len - 1)) {
            if (span0 == @intCast(i32, pwl0.points.items.len - 1)) {
                x = pwl1.points.items[span1 + 1].x();
                span1 += 1;
            } else if (span1 == @intCast(i32, pwl1.points.items.len - 1)) {
                x = pwl0.points.items[span0 + 1].x();
                span0 += 1;
            } else if (pwl0.points.items[span0 + 1].x() > pwl1.points.items[span1 + 1].x()) {
                x = pwl1.points.items[span1 + 1].x();
                span1 += 1;
            } else {
                x = pwl0.points.items[span0 + 1].x();
                span0 += 1;
            }
            f(x, pwl0.eval(x, &span0, false), pwl1.eval(x, &span1, false));
        }
    }

    pub fn combine(pwl0: Pwl, pwl1: Pwl, f: fn (f64, f64, f64) f64, eps: f64) Pwl {
        var result = Pwl.init();
        Pwl.map2(pwl0, pwl1, fn (x: f64, y0: f64, y1: f64) void {
            result.append(x, f(x, y0, y1), eps);
        });
        return result;
    }

    pub fn multiply(self: *Pwl, d: f64) void {
        for (self.points.items) |*pt| {
            pt[1] *= d;
        }
    }

    pub fn toString(self: Pwl) []u8 {
        var ss = std.StringWriter.init(std.heap.page_allocator);
        defer ss.deinit();
        ss.print("Pwl { ") catch {};
        for (self.points.items) |p| {
            ss.print("({f}, {f}) ", .{ p.x(), p.y() }) catch {};
        }
        ss.print("}") catch {};
        return ss.toOwnedSlice();
    }
};

const libcamera = @import("libcamera");

pub const RegionStats = struct {
    pub const Region = struct {
        val: anytype,
        counted: u32,
        uncounted: u32,
    };

    size: libcamera.Size,
    numFloating: u32,
    regions: std.ArrayList(Region),
    default: Region,

    pub fn init() RegionStats {
        return RegionStats{
            .size = libcamera.Size{ .width = 0, .height = 0 },
            .numFloating = 0,
            .regions = std.ArrayList(Region).init(std.heap.page_allocator),
            .default = Region{ .val = undefined, .counted = 0, .uncounted = 0 },
        };
    }

    pub fn initWithSize(size: libcamera.Size, numFloating: u32) RegionStats {
        var regions = std.ArrayList(Region).init(std.heap.page_allocator);
        regions.resize(size.width * size.height + numFloating) catch {};
        return RegionStats{
            .size = size,
            .numFloating = numFloating,
            .regions = regions,
            .default = Region{ .val = undefined, .counted = 0, .uncounted = 0 },
        };
    }

    pub fn initWithNum(num: u32) RegionStats {
        var regions = std.ArrayList(Region).init(std.heap.page_allocator);
        regions.resize(num) catch {};
        return RegionStats{
            .size = libcamera.Size{ .width = num, .height = 1 },
            .numFloating = 0,
            .regions = regions,
            .default = Region{ .val = undefined, .counted = 0, .uncounted = 0 },
        };
    }

    pub fn numRegions(self: *const RegionStats) u32 {
        return self.size.width * self.size.height;
    }

    pub fn numFloatingRegions(self: *const RegionStats) u32 {
        return self.numFloating;
    }

    pub fn set(self: *RegionStats, index: u32, region: Region) void {
        if (index >= self.numRegions()) return;
        self.set_(index, region);
    }

    pub fn setByPos(self: *RegionStats, pos: libcamera.Point, region: Region) void {
        self.set(pos.y * self.size.width + pos.x, region);
    }

    pub fn setFloating(self: *RegionStats, index: u32, region: Region) void {
        if (index >= self.numFloatingRegions()) return;
        self.set(self.numRegions() + index, region);
    }

    pub fn get(self: *const RegionStats, index: u32) Region {
        if (index >= self.numRegions()) return self.default;
        return self.get_(index);
    }

    pub fn getByPos(self: *const RegionStats, pos: libcamera.Point) Region {
        return self.get(pos.y * self.size.width + pos.x);
    }

    pub fn getFloating(self: *const RegionStats, index: u32) Region {
        if (index >= self.numFloatingRegions()) return self.default;
        return self.get_(self.numRegions() + index);
    }

    fn set_(self: *RegionStats, index: u32, region: Region) void {
        self.regions.items[index] = region;
    }

    fn get_(self: *const RegionStats, index: u32) Region {
        return self.regions.items[index];
    }
};

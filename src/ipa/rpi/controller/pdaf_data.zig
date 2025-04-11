const RegionStats = @import("region_stats");

pub const PdafData = struct {
    conf: u16, // Confidence, in arbitrary units
    phase: i16, // Phase error, in s16 Q4 format (S.11.4)
};

pub const PdafRegions = RegionStats(PdafData);

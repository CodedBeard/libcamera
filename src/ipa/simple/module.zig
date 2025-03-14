const std = @import("std");
const libcamera = @import("libcamera");

const IPAContext = @import("ipa_context.zig").IPAContext;
const IPAFrameContext = @import("ipa_context.zig").IPAFrameContext;
const IPAConfigInfo = @import("ipa_context.zig").IPAConfigInfo;
const DebayerParams = @import("libcamera/internal/software_isp/debayer_params.zig").DebayerParams;
const SwIspStats = @import("libcamera/internal/software_isp/swisp_stats.zig").SwIspStats;

pub const Module = libcamera.ipa.Module(IPAContext, IPAFrameContext, IPAConfigInfo, DebayerParams, SwIspStats);

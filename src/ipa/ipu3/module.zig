const std = @import("std");
const linux = @import("linux");

const libcamera = @import("libcamera");
const ipa = @import("libcamera.ipa");

const IPAContext = @import("ipa_context.zig").IPAContext;
const IPAFrameContext = @import("ipa_context.zig").IPAFrameContext;
const IPAConfigInfo = @import("libcamera.ipa.ipu3_ipa_interface.zig").IPAConfigInfo;
const ipu3_uapi_params = @import("linux.intel-ipu3.zig").ipu3_uapi_params;
const ipu3_uapi_stats_3a = @import("linux.intel-ipu3.zig").ipu3_uapi_stats_3a;

pub const Module = ipa.Module(IPAContext, IPAFrameContext, IPAConfigInfo, ipu3_uapi_params, ipu3_uapi_stats_3a);

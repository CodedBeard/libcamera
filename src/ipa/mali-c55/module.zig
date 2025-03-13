const std = @import("std");
const linux = @import("linux");
const libcamera = @import("libcamera");
const ipa = @import("libipa");

const IPAContext = @import("ipa_context.zig").IPAContext;
const IPAFrameContext = @import("ipa_context.zig").IPAFrameContext;
const IPACameraSensorInfo = @import("libcamera").IPACameraSensorInfo;
const mali_c55_params_buffer = @import("linux").mali_c55_params_buffer;
const mali_c55_stats_buffer = @import("linux").mali_c55_stats_buffer;

const Module = ipa.Module(IPAContext, IPAFrameContext, IPACameraSensorInfo, mali_c55_params_buffer, mali_c55_stats_buffer);

const std = @import("std");
const log = @import("log");

const FCQueue = struct {
    contexts: []FrameContext,

    pub fn init(size: u32) FCQueue {
        return FCQueue{
            .contexts = std.heap.page_allocator.alloc(FrameContext, size) catch unreachable,
        };
    }

    pub fn clear(self: *FCQueue) void {
        for (self.contexts) |*ctx| {
            ctx.initialised = false;
            ctx.frame = 0;
        }
    }

    pub fn alloc(self: *FCQueue, frame: u32) *FrameContext {
        const frameContext = &self.contexts[frame % self.contexts.len];

        if (frame != 0 and frame <= frameContext.frame) {
            log.warn("Frame {d} already initialised", .{frame});
        } else {
            self.initFrameContext(frameContext, frame);
        }

        return frameContext;
    }

    pub fn get(self: *FCQueue, frame: u32) *FrameContext {
        const frameContext = &self.contexts[frame % self.contexts.len];

        if (frame < frameContext.frame) {
            log.fatal("Frame context for {d} has been overwritten by {d}", .{frame, frameContext.frame});
        }

        if (frame == 0 and !frameContext.initialised) {
            self.initFrameContext(frameContext, frame);
            return frameContext;
        }

        if (frame == frameContext.frame) {
            return frameContext;
        }

        log.warn("Obtained an uninitialised FrameContext for {d}", .{frame});
        self.initFrameContext(frameContext, frame);

        return frameContext;
    }

    fn initFrameContext(self: *FCQueue, frameContext: *FrameContext, frame: u32) void {
        frameContext.* = FrameContext{
            .frame = frame,
            .initialised = true,
        };
    }
};

const FrameContext = struct {
    frame: u32,
    initialised: bool = false,
};

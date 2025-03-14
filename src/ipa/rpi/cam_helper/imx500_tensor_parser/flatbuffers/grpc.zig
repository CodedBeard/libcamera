const std = @import("std");
const flatbuffers = @import("flatbuffers");
const grpc = @import("grpc");

pub const Message = struct {
    slice: grpc.Slice,

    pub fn init(slice: grpc.Slice, add_ref: bool) Message {
        return Message{
            .slice = if (add_ref) grpc.slice_ref(slice) else slice,
        };
    }

    pub fn deinit(self: *Message) void {
        grpc.slice_unref(self.slice);
    }

    pub fn mutable_data(self: *Message) []u8 {
        return self.slice.ptr[0..self.slice.len];
    }

    pub fn data(self: *const Message) []const u8 {
        return self.slice.ptr[0..self.slice.len];
    }

    pub fn size(self: *const Message) usize {
        return self.slice.len;
    }

    pub fn verify(self: *const Message) bool {
        var verifier = flatbuffers.Verifier.init(self.data(), self.size());
        return verifier.verifyBuffer(T);
    }

    pub fn get_mutable_root(self: *Message) *T {
        return flatbuffers.getMutableRoot(T, self.mutable_data());
    }

    pub fn get_root(self: *const Message) *const T {
        return flatbuffers.getRoot(T, self.data());
    }

    pub fn borrow_slice(self: *const Message) grpc.Slice {
        return self.slice;
    }
};

pub const SliceAllocator = struct {
    slice: grpc.Slice,

    pub fn init() SliceAllocator {
        return SliceAllocator{
            .slice = grpc.empty_slice(),
        };
    }

    pub fn deinit(self: *SliceAllocator) void {
        grpc.slice_unref(self.slice);
    }

    pub fn allocate(self: *SliceAllocator, size: usize) []u8 {
        assert(self.slice.ptr == null);
        self.slice = grpc.slice_malloc(size);
        return self.slice.ptr[0..size];
    }

    pub fn deallocate(self: *SliceAllocator, p: []u8) void {
        assert(p.ptr == self.slice.ptr);
        grpc.slice_unref(self.slice);
        self.slice = grpc.empty_slice();
    }

    pub fn reallocate_downward(self: *SliceAllocator, old_p: []u8, new_size: usize, in_use_back: usize, in_use_front: usize) []u8 {
        assert(old_p.ptr == self.slice.ptr);
        var old_slice = self.slice;
        self.slice = grpc.slice_malloc(new_size);
        var new_p = self.slice.ptr[0..new_size];
        std.mem.copy(u8, new_p[in_use_front..in_use_front + in_use_back], old_p[0..in_use_back]);
        grpc.slice_unref(old_slice);
        return new_p;
    }
};

pub const MessageBuilder = struct {
    slice_allocator: SliceAllocator,
    builder: flatbuffers.Builder,

    pub fn init(initial_size: u32) MessageBuilder {
        var slice_allocator = SliceAllocator.init();
        return MessageBuilder{
            .slice_allocator = slice_allocator,
            .builder = flatbuffers.Builder.init(initial_size, &slice_allocator),
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        self.slice_allocator.deinit();
        self.builder.deinit();
    }

    pub fn get_message(self: *MessageBuilder) Message {
        var buf_data = self.builder.get_data();
        var buf_size = self.builder.get_size();
        var msg_data = self.builder.get_data();
        var msg_size = self.builder.get_size();
        assert(msg_data.ptr != null);
        assert(msg_size != 0);
        assert(msg_data.ptr >= buf_data.ptr);
        assert(msg_data.ptr + msg_size <= buf_data.ptr + buf_size);
        var begin = msg_data.ptr - buf_data.ptr;
        var end = begin + msg_size;
        var slice = self.slice_allocator.slice;
        var subslice = grpc.slice_sub(slice, begin, end);
        return Message.init(subslice, false);
    }

    pub fn release_message(self: *MessageBuilder) Message {
        var msg = self.get_message();
        self.builder.reset();
        return msg;
    }
};

pub fn serialize(msg: Message, buffer: *grpc.ByteBuffer, own_buffer: *bool) grpc.Status {
    var slice = msg.borrow_slice();
    *buffer = grpc.raw_byte_buffer_create(&slice, 1);
    *own_buffer = true;
    return grpc.Status.ok();
}

pub fn deserialize(buffer: *grpc.ByteBuffer, msg: *Message) grpc.Status {
    if (buffer == null) {
        return grpc.Status.internal("No payload");
    }
    if (buffer.type == grpc.BB_RAW and buffer.data.raw.compression == grpc.COMPRESS_NONE and buffer.data.raw.slice_buffer.count == 1) {
        var slice = buffer.data.raw.slice_buffer.slices[0];
        *msg = Message.init(slice, true);
    } else {
        var reader = grpc.ByteBufferReader.init(buffer);
        var slice = grpc.byte_buffer_reader_readall(&reader);
        grpc.byte_buffer_reader_destroy(&reader);
        *msg = Message.init(slice, false);
    }
    grpc.byte_buffer_destroy(buffer);
    if (msg.verify()) {
        return grpc.Status.ok();
    } else {
        return grpc.Status.internal("Message verification failed");
    }
}

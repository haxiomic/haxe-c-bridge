import cpp.CastCharStar;

// extern for struct MessagePayload
@:include('./MessagePayload.h')
@:structAccess
extern class MessagePayload {
	var someFloat: cpp.Float32;
	var cStr: CastCharStar;

	@:native('~MessagePayload')
	function free(): Void;

	@:native('new MessagePayload')
	static function alloc(): cpp.Star<MessagePayload>;

	@:native('MessagePayload')
	static function stackAlloc(): MessagePayload;
}
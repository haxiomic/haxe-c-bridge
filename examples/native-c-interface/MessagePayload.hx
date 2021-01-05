import cpp.ConstCharStar;

// extern for struct MessagePayload
@:include('./MessagePayload.h')
@:structAccess
extern class MessagePayload {
	var someFloat: cpp.Float32;
	var cStr: ConstCharStar;
}
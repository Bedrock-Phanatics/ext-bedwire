/* This is a generated file, edit the .stub.php file instead.
 * Stub hash: d169e447600449f6a817c24ba6c503236e038551 */

ZEND_BEGIN_ARG_INFO_EX(arginfo_class_Bedwire_Server___construct, 0, 0, 2)
	ZEND_ARG_TYPE_INFO(0, address, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, port, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, options, IS_ARRAY, 0, "[]")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_stop, 0, 0, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, timeoutMs, IS_LONG, 0, "2000")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_isRunning, 0, 0, _IS_BOOL, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_getPort, 0, 0, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_setStatus, 0, 3, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, name, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, level, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, maxPlayers, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, gameType, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_poll, 0, 0, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxEvents, IS_LONG, 0, "4096")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, timeoutMs, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_send, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, packet, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_sendBatch, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, packets, IS_ARRAY, 0)
ZEND_END_ARG_INFO()

#define arginfo_class_Bedwire_Server_sendPackets arginfo_class_Bedwire_Server_sendBatch

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_sendRawBatch, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, batch, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, offset, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_sendUnreliable, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, payload, IS_STRING, 0)
ZEND_END_ARG_INFO()

#define arginfo_class_Bedwire_Server_eventSignal arginfo_class_Bedwire_Server_getPort

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_waitForEvents, 0, 2, IS_LONG, 1)
	ZEND_ARG_TYPE_INFO(0, signal, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, seen, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, timeoutMs, IS_LONG, 0, "1000")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_disconnect, 0, 1, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_acceptLogin, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, clientKeyDer, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_getStatistics, 0, 0, IS_ARRAY, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_class_Bedwire_Protocol___construct, 0, 0, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_id, 0, 1, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, name, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_name, 0, 1, IS_STRING, 1)
	ZEND_ARG_TYPE_INFO(0, id, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_direction, 0, 1, IS_LONG, 0)
	ZEND_ARG_TYPE_MASK(0, packet, MAY_BE_LONG|MAY_BE_STRING, NULL)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_header, 0, 1, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, bytes, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_packetId, 0, 1, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, bytes, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_decode, 0, 1, IS_ARRAY, 1)
	ZEND_ARG_TYPE_INFO(0, bytes, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_decodeMany, 0, 1, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, packets, IS_ARRAY, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Protocol_encode, 0, 2, IS_STRING, 0)
	ZEND_ARG_TYPE_MASK(0, packet, MAY_BE_LONG|MAY_BE_STRING, NULL)
	ZEND_ARG_TYPE_INFO(0, fields, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, senderSubClient, IS_LONG, 0, "0")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, targetSubClient, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

#define arginfo_class_Bedwire_Protocol_encodeMany arginfo_class_Bedwire_Protocol_decodeMany

#define arginfo_class_Bedwire_Nbt___construct arginfo_class_Bedwire_Protocol___construct

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_transcode, 0, 3, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, from, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, to, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_length, 0, 2, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, offset, IS_LONG, 0, "0")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_OBJ_INFO_EX(arginfo_class_Bedwire_Nbt_read, 0, 2, pocketmine\\nbt\\TreeRoot, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, offset, IS_LONG, 0, "0")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_readAt, 0, 2, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, offset, IS_LONG, 0, "0")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_OBJ_INFO_EX(arginfo_class_Bedwire_Nbt_readHeadless, 0, 3, pocketmine\\nbt\\tag\\Tag, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, type, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, offset, IS_LONG, 0, "0")
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_readMultiple, 0, 2, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "0")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_write, 0, 2, IS_STRING, 0)
	ZEND_ARG_OBJ_INFO(0, root, pocketmine\\nbt\\TreeRoot, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_writeHeadless, 0, 2, IS_STRING, 0)
	ZEND_ARG_OBJ_INFO(0, tag, pocketmine\\nbt\\tag\\Tag, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_writeMultiple, 0, 2, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, roots, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, format, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_METHOD(Bedwire_Server, __construct);
ZEND_METHOD(Bedwire_Server, stop);
ZEND_METHOD(Bedwire_Server, isRunning);
ZEND_METHOD(Bedwire_Server, getPort);
ZEND_METHOD(Bedwire_Server, setStatus);
ZEND_METHOD(Bedwire_Server, poll);
ZEND_METHOD(Bedwire_Server, send);
ZEND_METHOD(Bedwire_Server, sendBatch);
ZEND_METHOD(Bedwire_Server, sendPackets);
ZEND_METHOD(Bedwire_Server, sendRawBatch);
ZEND_METHOD(Bedwire_Server, sendUnreliable);
ZEND_METHOD(Bedwire_Server, eventSignal);
ZEND_METHOD(Bedwire_Server, waitForEvents);
ZEND_METHOD(Bedwire_Server, disconnect);
ZEND_METHOD(Bedwire_Server, acceptLogin);
ZEND_METHOD(Bedwire_Server, getStatistics);
ZEND_METHOD(Bedwire_Protocol, __construct);
ZEND_METHOD(Bedwire_Protocol, id);
ZEND_METHOD(Bedwire_Protocol, name);
ZEND_METHOD(Bedwire_Protocol, direction);
ZEND_METHOD(Bedwire_Protocol, header);
ZEND_METHOD(Bedwire_Protocol, packetId);
ZEND_METHOD(Bedwire_Protocol, decode);
ZEND_METHOD(Bedwire_Protocol, decodeMany);
ZEND_METHOD(Bedwire_Protocol, encode);
ZEND_METHOD(Bedwire_Protocol, encodeMany);
ZEND_METHOD(Bedwire_Nbt, __construct);
ZEND_METHOD(Bedwire_Nbt, transcode);
ZEND_METHOD(Bedwire_Nbt, length);
ZEND_METHOD(Bedwire_Nbt, read);
ZEND_METHOD(Bedwire_Nbt, readAt);
ZEND_METHOD(Bedwire_Nbt, readHeadless);
ZEND_METHOD(Bedwire_Nbt, readMultiple);
ZEND_METHOD(Bedwire_Nbt, write);
ZEND_METHOD(Bedwire_Nbt, writeHeadless);
ZEND_METHOD(Bedwire_Nbt, writeMultiple);

static const zend_function_entry class_Bedwire_Server_methods[] = {
	ZEND_ME(Bedwire_Server, __construct, arginfo_class_Bedwire_Server___construct, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, stop, arginfo_class_Bedwire_Server_stop, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, isRunning, arginfo_class_Bedwire_Server_isRunning, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, getPort, arginfo_class_Bedwire_Server_getPort, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, setStatus, arginfo_class_Bedwire_Server_setStatus, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, poll, arginfo_class_Bedwire_Server_poll, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, send, arginfo_class_Bedwire_Server_send, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendBatch, arginfo_class_Bedwire_Server_sendBatch, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendPackets, arginfo_class_Bedwire_Server_sendPackets, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendRawBatch, arginfo_class_Bedwire_Server_sendRawBatch, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendUnreliable, arginfo_class_Bedwire_Server_sendUnreliable, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, eventSignal, arginfo_class_Bedwire_Server_eventSignal, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, waitForEvents, arginfo_class_Bedwire_Server_waitForEvents, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Server, disconnect, arginfo_class_Bedwire_Server_disconnect, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, acceptLogin, arginfo_class_Bedwire_Server_acceptLogin, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, getStatistics, arginfo_class_Bedwire_Server_getStatistics, ZEND_ACC_PUBLIC)
	ZEND_FE_END
};

static const zend_function_entry class_Bedwire_Protocol_methods[] = {
	ZEND_ME(Bedwire_Protocol, __construct, arginfo_class_Bedwire_Protocol___construct, ZEND_ACC_PRIVATE)
	ZEND_ME(Bedwire_Protocol, id, arginfo_class_Bedwire_Protocol_id, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, name, arginfo_class_Bedwire_Protocol_name, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, direction, arginfo_class_Bedwire_Protocol_direction, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, header, arginfo_class_Bedwire_Protocol_header, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, packetId, arginfo_class_Bedwire_Protocol_packetId, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, decode, arginfo_class_Bedwire_Protocol_decode, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, decodeMany, arginfo_class_Bedwire_Protocol_decodeMany, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, encode, arginfo_class_Bedwire_Protocol_encode, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Protocol, encodeMany, arginfo_class_Bedwire_Protocol_encodeMany, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_FE_END
};

static const zend_function_entry class_Bedwire_Nbt_methods[] = {
	ZEND_ME(Bedwire_Nbt, __construct, arginfo_class_Bedwire_Nbt___construct, ZEND_ACC_PRIVATE)
	ZEND_ME(Bedwire_Nbt, transcode, arginfo_class_Bedwire_Nbt_transcode, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, length, arginfo_class_Bedwire_Nbt_length, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, read, arginfo_class_Bedwire_Nbt_read, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, readAt, arginfo_class_Bedwire_Nbt_readAt, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, readHeadless, arginfo_class_Bedwire_Nbt_readHeadless, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, readMultiple, arginfo_class_Bedwire_Nbt_readMultiple, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, write, arginfo_class_Bedwire_Nbt_write, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, writeHeadless, arginfo_class_Bedwire_Nbt_writeHeadless, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_ME(Bedwire_Nbt, writeMultiple, arginfo_class_Bedwire_Nbt_writeMultiple, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
	ZEND_FE_END
};

static zend_class_entry *register_class_Bedwire_Exception(zend_class_entry *class_entry_RuntimeException)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Exception", NULL);
	class_entry = zend_register_internal_class_with_flags(&ce, class_entry_RuntimeException, 0);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_BackpressureException(zend_class_entry *class_entry_Bedwire_Exception)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "BackpressureException", NULL);
	class_entry = zend_register_internal_class_with_flags(&ce, class_entry_Bedwire_Exception, ZEND_ACC_FINAL);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_PacketException(zend_class_entry *class_entry_Bedwire_Exception)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "PacketException", NULL);
	class_entry = zend_register_internal_class_with_flags(&ce, class_entry_Bedwire_Exception, ZEND_ACC_FINAL);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_NbtException(zend_class_entry *class_entry_Bedwire_Exception)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "NbtException", NULL);
	class_entry = zend_register_internal_class_with_flags(&ce, class_entry_Bedwire_Exception, ZEND_ACC_FINAL);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_Server(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Server", class_Bedwire_Server_methods);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL|ZEND_ACC_NO_DYNAMIC_PROPERTIES|ZEND_ACC_NOT_SERIALIZABLE);

	zval const_EVENT_CONNECT_value;
	ZVAL_LONG(&const_EVENT_CONNECT_value, 1);
	zend_string *const_EVENT_CONNECT_name = zend_string_init_interned("EVENT_CONNECT", sizeof("EVENT_CONNECT") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_CONNECT_name, &const_EVENT_CONNECT_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_CONNECT_name);

	zval const_EVENT_DISCONNECT_value;
	ZVAL_LONG(&const_EVENT_DISCONNECT_value, 2);
	zend_string *const_EVENT_DISCONNECT_name = zend_string_init_interned("EVENT_DISCONNECT", sizeof("EVENT_DISCONNECT") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_DISCONNECT_name, &const_EVENT_DISCONNECT_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_DISCONNECT_name);

	zval const_EVENT_PACKET_value;
	ZVAL_LONG(&const_EVENT_PACKET_value, 3);
	zend_string *const_EVENT_PACKET_name = zend_string_init_interned("EVENT_PACKET", sizeof("EVENT_PACKET") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_PACKET_name, &const_EVENT_PACKET_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_PACKET_name);

	zval const_EVENT_LOGIN_value;
	ZVAL_LONG(&const_EVENT_LOGIN_value, 4);
	zend_string *const_EVENT_LOGIN_name = zend_string_init_interned("EVENT_LOGIN", sizeof("EVENT_LOGIN") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_LOGIN_name, &const_EVENT_LOGIN_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_LOGIN_name);

	zval const_EVENT_UNRELIABLE_value;
	ZVAL_LONG(&const_EVENT_UNRELIABLE_value, 5);
	zend_string *const_EVENT_UNRELIABLE_name = zend_string_init_interned("EVENT_UNRELIABLE", sizeof("EVENT_UNRELIABLE") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_UNRELIABLE_name, &const_EVENT_UNRELIABLE_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_UNRELIABLE_name);

	zval const_REASON_REMOTE_value;
	ZVAL_LONG(&const_REASON_REMOTE_value, 0);
	zend_string *const_REASON_REMOTE_name = zend_string_init_interned("REASON_REMOTE", sizeof("REASON_REMOTE") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_REMOTE_name, &const_REASON_REMOTE_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_REMOTE_name);

	zval const_REASON_SERVER_value;
	ZVAL_LONG(&const_REASON_SERVER_value, 1);
	zend_string *const_REASON_SERVER_name = zend_string_init_interned("REASON_SERVER", sizeof("REASON_SERVER") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_SERVER_name, &const_REASON_SERVER_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_SERVER_name);

	zval const_REASON_PROTOCOL_value;
	ZVAL_LONG(&const_REASON_PROTOCOL_value, 2);
	zend_string *const_REASON_PROTOCOL_name = zend_string_init_interned("REASON_PROTOCOL", sizeof("REASON_PROTOCOL") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_PROTOCOL_name, &const_REASON_PROTOCOL_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_PROTOCOL_name);

	zval const_REASON_OVERLOAD_value;
	ZVAL_LONG(&const_REASON_OVERLOAD_value, 3);
	zend_string *const_REASON_OVERLOAD_name = zend_string_init_interned("REASON_OVERLOAD", sizeof("REASON_OVERLOAD") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_OVERLOAD_name, &const_REASON_OVERLOAD_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_OVERLOAD_name);

	zval const_REASON_SHUTDOWN_value;
	ZVAL_LONG(&const_REASON_SHUTDOWN_value, 4);
	zend_string *const_REASON_SHUTDOWN_name = zend_string_init_interned("REASON_SHUTDOWN", sizeof("REASON_SHUTDOWN") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_SHUTDOWN_name, &const_REASON_SHUTDOWN_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_SHUTDOWN_name);

	zval const_REASON_AUTHENTICATION_value;
	ZVAL_LONG(&const_REASON_AUTHENTICATION_value, 5);
	zend_string *const_REASON_AUTHENTICATION_name = zend_string_init_interned("REASON_AUTHENTICATION", sizeof("REASON_AUTHENTICATION") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_AUTHENTICATION_name, &const_REASON_AUTHENTICATION_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_AUTHENTICATION_name);

	zval const_REASON_TIMEOUT_value;
	ZVAL_LONG(&const_REASON_TIMEOUT_value, 6);
	zend_string *const_REASON_TIMEOUT_name = zend_string_init_interned("REASON_TIMEOUT", sizeof("REASON_TIMEOUT") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_REASON_TIMEOUT_name, &const_REASON_TIMEOUT_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_REASON_TIMEOUT_name);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_Protocol(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Protocol", class_Bedwire_Protocol_methods);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL|ZEND_ACC_NOT_SERIALIZABLE);

	zval const_CLIENTBOUND_value;
	ZVAL_LONG(&const_CLIENTBOUND_value, 1);
	zend_string *const_CLIENTBOUND_name = zend_string_init_interned("CLIENTBOUND", sizeof("CLIENTBOUND") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_CLIENTBOUND_name, &const_CLIENTBOUND_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_CLIENTBOUND_name);

	zval const_SERVERBOUND_value;
	ZVAL_LONG(&const_SERVERBOUND_value, 2);
	zend_string *const_SERVERBOUND_name = zend_string_init_interned("SERVERBOUND", sizeof("SERVERBOUND") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_SERVERBOUND_name, &const_SERVERBOUND_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_SERVERBOUND_name);

	zval const_BIDIRECTIONAL_value;
	ZVAL_LONG(&const_BIDIRECTIONAL_value, 3);
	zend_string *const_BIDIRECTIONAL_name = zend_string_init_interned("BIDIRECTIONAL", sizeof("BIDIRECTIONAL") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_BIDIRECTIONAL_name, &const_BIDIRECTIONAL_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_BIDIRECTIONAL_name);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_PacketId(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "PacketId", NULL);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL|ZEND_ACC_NOT_SERIALIZABLE);

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_Nbt(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Nbt", class_Bedwire_Nbt_methods);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL|ZEND_ACC_NOT_SERIALIZABLE);

	zval const_JAVA_value;
	ZVAL_LONG(&const_JAVA_value, 0);
	zend_string *const_JAVA_name = zend_string_init_interned("JAVA", sizeof("JAVA") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_JAVA_name, &const_JAVA_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_JAVA_name);

	zval const_BEDROCK_value;
	ZVAL_LONG(&const_BEDROCK_value, 1);
	zend_string *const_BEDROCK_name = zend_string_init_interned("BEDROCK", sizeof("BEDROCK") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_BEDROCK_name, &const_BEDROCK_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_BEDROCK_name);

	zval const_NETWORK_value;
	ZVAL_LONG(&const_NETWORK_value, 2);
	zend_string *const_NETWORK_name = zend_string_init_interned("NETWORK", sizeof("NETWORK") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_NETWORK_name, &const_NETWORK_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_NETWORK_name);

	return class_entry;
}

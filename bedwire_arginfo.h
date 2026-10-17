/* This is a generated file, edit the .stub.php file instead.
 * Stub hash: 34ce8c41b324628c1366d8346c824f6d35cae498 */

ZEND_BEGIN_ARG_INFO_EX(arginfo_class_Bedwire_Server___construct, 0, 0, 3)
	ZEND_ARG_TYPE_INFO(0, address, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, port, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, advertisement, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, options, IS_ARRAY, 0, "[]")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_stop, 0, 0, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, timeoutMs, IS_LONG, 0, "2000")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_isRunning, 0, 0, _IS_BOOL, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_getPort, 0, 0, IS_LONG, 0)
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

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_MASK_EX(arginfo_class_Bedwire_Server_sendWithReceipt, 0, 2, MAY_BE_LONG|MAY_BE_FALSE)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, packets, IS_ARRAY, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_disconnect, 0, 1, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_enableEncryption, 0, 3, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, handshakePacket, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, key, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_acceptLogin, 0, 2, _IS_BOOL, 0)
	ZEND_ARG_TYPE_INFO(0, session, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, clientPublicKey, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_setAdvertisement, 0, 1, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, advertisement, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_blockAddress, 0, 1, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, address, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, seconds, IS_LONG, 0, "300")
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_unblockAddress, 0, 1, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, address, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_sendRaw, 0, 3, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, address, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, port, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, payload, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Server_getStatistics, 0, 0, IS_ARRAY, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_INFO_EX(arginfo_class_Bedwire_Nbt___construct, 0, 0, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_class_Bedwire_Nbt_transcode, 0, 3, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, data, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, from, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, to, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, maxDepth, IS_LONG, 0, "512")
ZEND_END_ARG_INFO()

ZEND_METHOD(Bedwire_Server, __construct);
ZEND_METHOD(Bedwire_Server, stop);
ZEND_METHOD(Bedwire_Server, isRunning);
ZEND_METHOD(Bedwire_Server, getPort);
ZEND_METHOD(Bedwire_Server, poll);
ZEND_METHOD(Bedwire_Server, send);
ZEND_METHOD(Bedwire_Server, sendBatch);
ZEND_METHOD(Bedwire_Server, sendWithReceipt);
ZEND_METHOD(Bedwire_Server, disconnect);
ZEND_METHOD(Bedwire_Server, enableEncryption);
ZEND_METHOD(Bedwire_Server, acceptLogin);
ZEND_METHOD(Bedwire_Server, setAdvertisement);
ZEND_METHOD(Bedwire_Server, blockAddress);
ZEND_METHOD(Bedwire_Server, unblockAddress);
ZEND_METHOD(Bedwire_Server, sendRaw);
ZEND_METHOD(Bedwire_Server, getStatistics);
ZEND_METHOD(Bedwire_Nbt, __construct);
ZEND_METHOD(Bedwire_Nbt, transcode);

static const zend_function_entry class_Bedwire_Server_methods[] = {
	ZEND_ME(Bedwire_Server, __construct, arginfo_class_Bedwire_Server___construct, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, stop, arginfo_class_Bedwire_Server_stop, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, isRunning, arginfo_class_Bedwire_Server_isRunning, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, getPort, arginfo_class_Bedwire_Server_getPort, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, poll, arginfo_class_Bedwire_Server_poll, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, send, arginfo_class_Bedwire_Server_send, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendBatch, arginfo_class_Bedwire_Server_sendBatch, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendWithReceipt, arginfo_class_Bedwire_Server_sendWithReceipt, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, disconnect, arginfo_class_Bedwire_Server_disconnect, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, enableEncryption, arginfo_class_Bedwire_Server_enableEncryption, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, acceptLogin, arginfo_class_Bedwire_Server_acceptLogin, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, setAdvertisement, arginfo_class_Bedwire_Server_setAdvertisement, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, blockAddress, arginfo_class_Bedwire_Server_blockAddress, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, unblockAddress, arginfo_class_Bedwire_Server_unblockAddress, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, sendRaw, arginfo_class_Bedwire_Server_sendRaw, ZEND_ACC_PUBLIC)
	ZEND_ME(Bedwire_Server, getStatistics, arginfo_class_Bedwire_Server_getStatistics, ZEND_ACC_PUBLIC)
	ZEND_FE_END
};

static const zend_function_entry class_Bedwire_Nbt_methods[] = {
	ZEND_ME(Bedwire_Nbt, __construct, arginfo_class_Bedwire_Nbt___construct, ZEND_ACC_PRIVATE)
	ZEND_ME(Bedwire_Nbt, transcode, arginfo_class_Bedwire_Nbt_transcode, ZEND_ACC_PUBLIC|ZEND_ACC_STATIC)
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

static zend_class_entry *register_class_Bedwire_Server(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Server", class_Bedwire_Server_methods);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL);

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

	zval const_EVENT_RECEIPT_ACK_value;
	ZVAL_LONG(&const_EVENT_RECEIPT_ACK_value, 4);
	zend_string *const_EVENT_RECEIPT_ACK_name = zend_string_init_interned("EVENT_RECEIPT_ACK", sizeof("EVENT_RECEIPT_ACK") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_RECEIPT_ACK_name, &const_EVENT_RECEIPT_ACK_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_RECEIPT_ACK_name);

	zval const_EVENT_RECEIPT_FAILED_value;
	ZVAL_LONG(&const_EVENT_RECEIPT_FAILED_value, 5);
	zend_string *const_EVENT_RECEIPT_FAILED_name = zend_string_init_interned("EVENT_RECEIPT_FAILED", sizeof("EVENT_RECEIPT_FAILED") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_RECEIPT_FAILED_name, &const_EVENT_RECEIPT_FAILED_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_RECEIPT_FAILED_name);

	zval const_EVENT_PING_value;
	ZVAL_LONG(&const_EVENT_PING_value, 6);
	zend_string *const_EVENT_PING_name = zend_string_init_interned("EVENT_PING", sizeof("EVENT_PING") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_PING_name, &const_EVENT_PING_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_PING_name);

	zval const_EVENT_RAW_value;
	ZVAL_LONG(&const_EVENT_RAW_value, 7);
	zend_string *const_EVENT_RAW_name = zend_string_init_interned("EVENT_RAW", sizeof("EVENT_RAW") - 1, 1);
	zend_declare_typed_class_constant(class_entry, const_EVENT_RAW_name, &const_EVENT_RAW_value, ZEND_ACC_PUBLIC, NULL, (zend_type) ZEND_TYPE_INIT_MASK(MAY_BE_LONG));
	zend_string_release(const_EVENT_RAW_name);

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

	return class_entry;
}

static zend_class_entry *register_class_Bedwire_Nbt(void)
{
	zend_class_entry ce, *class_entry;

	INIT_NS_CLASS_ENTRY(ce, "Bedwire", "Nbt", class_Bedwire_Nbt_methods);
	class_entry = zend_register_internal_class_with_flags(&ce, NULL, ZEND_ACC_FINAL);

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

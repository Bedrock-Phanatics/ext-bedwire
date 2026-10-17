--TEST--
Unknown, stale and malformed session IDs are refused without side effects
--EXTENSIONS--
bedwire
--FILE--
<?php
$server = new Bedwire\Server("127.0.0.1", 0, "MCPE;phpt;2193;1.0;0;10;1;w;Survival;1;19132;19133;");
$results = [];
foreach ([0, 1, 1 << 16, (5 << 16) | 3, -1, PHP_INT_MAX, PHP_INT_MIN] as $id) {
    $results[] = $server->send($id, "\x01\x02");
    $results[] = $server->sendBatch($id, ["\x01", "\x02"]);
    $results[] = $server->sendWithReceipt($id, ["\x01"]);
    $results[] = $server->disconnect($id);
    $results[] = $server->enableEncryption($id, "\x03\x00", str_repeat("k", 32));
    $results[] = $server->acceptLogin($id, "der");
}
var_dump(count($results), array_unique($results, SORT_REGULAR));
var_dump($server->poll(16, 20));
var_dump($server->getStatistics()["sessions"]);
$server->stop(0);
?>
--EXPECT--
int(42)
array(1) {
  [0]=>
  bool(false)
}
array(0) {
}
int(0)

--TEST--
Unions of distinct structs stand for themselves as their variant's object once every variant is bound
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\{PacketId, Protocol};

interface Body{}
final class Text{
    public function __construct(public bool $localize, public object|array $body, public string $sendersXuid, public string $platformId, public ?string $filteredMessage = null){}
}
final class ArrayText{
    public function __construct(public bool $localize, public array $body, public string $sendersXuid, public string $platformId, public ?string $filteredMessage = null){}
}
class MessageOnly implements Body{
    public function __construct(public int $messageType, public string $message){}
}
final class Shouted extends MessageOnly{}
final class AuthorAndMessage implements Body{
    public function __construct(public int $messageType, public string $playerName, public string $message){}
}
final class MessageAndParams implements Body{
    public function __construct(public int $messageType, public string $message, public array $parameterList){}
}
final class Other{}

function attempt(callable $fn): void{
    try{
        $fn();
        echo "ok\n";
    }catch(Throwable $e){
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

$fields = ["localize" => false, "body" => ["author_and_message" => ["message_type" => 1, "player_name" => "Steve", "message" => "hi"]], "senders_xuid" => "", "platform_id" => ""];
$bytes = Protocol::encode(PacketId::TEXT, $fields);
$variants = ["TextMessageOnly" => MessageOnly::class, "TextAuthorAndMessage" => AuthorAndMessage::class, "TextMessageAndParams" => MessageAndParams::class];

Protocol::bind(["text" => Text::class] + $variants);
$text = Protocol::decode($bytes);
var_dump($text->body instanceof AuthorAndMessage, $text->body->playerName);
var_dump(Protocol::encode(PacketId::TEXT, $text) === $bytes);
var_dump(Protocol::encode(PacketId::TEXT, $fields) === $bytes);
var_dump(Protocol::encode(PacketId::TEXT, new Text(false, new Shouted(0, "a"), "", "")) === Protocol::encode(PacketId::TEXT, new Text(false, new MessageOnly(0, "a"), "", "")));
attempt(fn() => Protocol::encode(PacketId::TEXT, new Text(false, ["message_only" => new MessageOnly(0, "a")], "", "")));
attempt(fn() => Protocol::encode(PacketId::TEXT, new Text(false, new Other(), "", "")));

Protocol::bind(["text" => ArrayText::class, "TextMessageOnly" => MessageOnly::class]);
$text = Protocol::decode($bytes);
var_dump($text->body === $fields["body"]);

attempt(fn() => Protocol::bind(["text" => ArrayText::class] + $variants));
attempt(fn() => Protocol::bind(["TextMessageOnly" => MessageOnly::class, "TextAuthorAndMessage" => Shouted::class, "TextMessageAndParams" => MessageAndParams::class]));
?>
--EXPECT--
bool(true)
string(5) "Steve"
bool(true)
bool(true)
bool(true)
ok
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) body is an object of none of its variant classes, Other given
bool(true)
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds text to ArrayText, whose property body does not accept an array or its variant classes
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds two variants of one union to related classes MessageOnly and Shouted

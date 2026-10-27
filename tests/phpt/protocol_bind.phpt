--TEST--
Bound classes are decoded into and encoded from by property slot, and classes that do not fit are refused
--EXTENSIONS--
bedwire
--FILE--
<?php
use Bedwire\{PacketId, Protocol};

class Vec{
    public function __construct(public float|int $x, public float|int $y, public float|int $z){}
}
final class Place extends Vec{
    public ?string $world = null;
}
final class Move{
    public function __construct(public int $actorRuntimeId, public int $header, public Vec $position, public int $rotationX = 0, public int $rotationY = 0, public int $rotationYHead = 0){}
}
final class Time{
    public function __construct(public int $time){}
}
final class Typo{ public int $tme; }
final class Text{ public string $time; }
final class Hooked{ public int $time { get => 1; } }
abstract class Abstracted{ public int $time; }

function attempt(callable $fn): void{
    try{
        $fn();
        echo "ok\n";
    }catch(Throwable $e){
        echo get_class($e), ": ", $e->getMessage(), "\n";
    }
}

$fields = ["move_data" => ["actor_runtime_id" => 7, "header" => 1, "position" => ["x" => 1.5, "y" => 64.0, "z" => -3.25], "rotation_x" => 8, "rotation_y" => 64, "rotation_y_head" => 32]];
$bytes = Protocol::encode(PacketId::MOVE_ACTOR_ABSOLUTE, $fields);
$time = Protocol::encode(PacketId::SET_TIME, ["time" => 9]);

Protocol::bind(["move_actor_absolute" => Move::class, "Vec3f" => Vec::class, "set_time" => Time::class]);
$move = Protocol::decode($bytes);
var_dump($move instanceof Move, $move->position instanceof Vec, $move->position->z, $move->rotationYHead);
var_dump(Protocol::encode(PacketId::MOVE_ACTOR_ABSOLUTE, $move) === $bytes);
var_dump(Protocol::encode(PacketId::MOVE_ACTOR_ABSOLUTE, new Move(7, 1, new Place(1.5, 64, -3.25), 8, 64, 32)) === $bytes);
var_dump(Protocol::encode(PacketId::MOVE_ACTOR_ABSOLUTE, $fields) === $bytes);
var_dump(Protocol::encodeBatch([[PacketId::MOVE_ACTOR_ABSOLUTE, $move], [PacketId::SET_TIME, new Time(9)]]) === Protocol::encodeBatch([$bytes, $time]));
var_dump(Protocol::decodeMany([$time])[0] == new Time(9));

attempt(fn() => Protocol::encode(PacketId::SET_TIME, new Move(7, 1, new Vec(0, 0, 0))));
attempt(fn() => Protocol::encode(PacketId::SET_TIME, (new ReflectionClass(Time::class))->newInstanceWithoutConstructor()));
attempt(fn() => Protocol::encode(PacketId::SET_TIME, (new ReflectionClass(Time::class))->newLazyGhost(function(Time $time){ $time->time = 9; })));
attempt(fn() => Protocol::decode($bytes, 3));

attempt(fn() => Protocol::bind(["set_time" => Typo::class]));
attempt(fn() => Protocol::bind(["set_time" => Text::class]));
attempt(fn() => Protocol::bind(["set_time" => Hooked::class]));
attempt(fn() => Protocol::bind(["set_time" => Abstracted::class]));
attempt(fn() => Protocol::bind(["set_time" => "Missing"]));
attempt(fn() => Protocol::bind(["no_such_packet" => Time::class]));
attempt(fn() => Protocol::bind(["move_actor_absolute" => Move::class]));
var_dump(Protocol::decode($time) instanceof Time);

Protocol::bind([]);
var_dump(Protocol::decode($bytes) === $fields);
?>
--EXPECT--
bool(true)
bool(true)
float(-3.25)
int(32)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) value is an object of the wrong class, Move given
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) time is not initialized
ValueError: Bedwire\Protocol::encode(): Argument #2 ($fields) value must not be a lazy object
Bedwire\PacketException: malformed packet: TooManyValues
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds set_time to Typo, which has no property time
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds set_time to Text, whose property time does not accept int
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds set_time to Hooked, whose property time is not a plain instance property
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds set_time to Abstracted, which cannot be created as a plain object
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds set_time to an unknown class
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) names an unknown struct or packet no_such_packet
ValueError: Bedwire\Protocol::bind(): Argument #1 ($types) binds MoveActorAbsoluteData to Move, whose property position does not accept an array or its bound class
bool(true)
bool(true)

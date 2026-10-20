<?php
// Mirrors pocketmine/nbt 1.2's declared properties, which is all the extension relies on.
namespace pocketmine\nbt\tag {
    abstract class Tag { protected $cloning = false; }
    abstract class ImmutableTag extends Tag {}
    final class ByteTag extends ImmutableTag { private $value; public function __construct(int $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class ShortTag extends ImmutableTag { private $value; public function __construct(int $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class IntTag extends ImmutableTag { private $value; public function __construct(int $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class LongTag extends ImmutableTag { private $value; public function __construct(int $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class FloatTag extends ImmutableTag { private $value; public function __construct(float $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class DoubleTag extends ImmutableTag { private $value; public function __construct(float $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class StringTag extends ImmutableTag { private $value; public function __construct(string $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class ByteArrayTag extends ImmutableTag { private $value; public function __construct(string $value) { $this->value = $value; } public function getValue() { return $this->value; } }
    final class IntArrayTag extends ImmutableTag { private $value; public function __construct(array $value) { $this->value = array_values($value); } public function getValue() { return $this->value; } }
    final class ListTag extends Tag {
        private $tagType;
        private $value = [];
        public function __construct(array $value = [], int $tagType = 0) { $this->tagType = $tagType; $this->value = array_values($value); }
        public function getValue() { return $this->value; }
        public function getTagType() { return $this->tagType; }
    }
    final class CompoundTag extends Tag {
        private $value = [];
        public function setTag(string $name, Tag $tag) { $this->value[$name] = $tag; return $this; }
        public function getValue() { return $this->value; }
    }
}

namespace pocketmine\nbt {
    final class TreeRoot {
        private $root;
        private $name;
        public function __construct(tag\Tag $root, string $name = "") { $this->root = $root; $this->name = $name; }
        public function getTag() { return $this->root; }
        public function getName() { return $this->name; }
    }
}

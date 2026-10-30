# Tests tagged :vulkan need a Vulkan driver (any: lavapipe, Mesa's software
# one, will do). Without one they're skipped, and say so.
vulkan? =
  match?({_, 0}, System.cmd("sh", ["-c", "vulkaninfo --summary"], stderr_to_stdout: true))

unless vulkan?, do: IO.puts("no Vulkan driver (vulkaninfo failed): skipping the :vulkan tests")

# Tests tagged :ligature_font need JetBrains Mono, a font with ligatures.
{families, _} = System.cmd("sh", ["-c", "fc-list : family"])
ligature_font? = families =~ ~r/^JetBrains ?Mono( Nerd Font Mono)?(,|$)/m
unless ligature_font?, do: IO.puts("no JetBrains Mono: skipping the :ligature_font tests")

ExUnit.start(
  exclude:
    if(vulkan?, do: [], else: [:vulkan]) ++ if(ligature_font?, do: [], else: [:ligature_font])
)

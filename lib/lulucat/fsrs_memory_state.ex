defmodule Fsrs.MemoryState do
  @moduledoc """
  The memory state of an item. Mirrors `fsrs::MemoryState`.

  - `stability` — the (slow) stability trace, in days
  - `difficulty` — between `1.0` and `10.0`
  - `stability_fast` — the fast stability trace used by FSRS-7; for FSRS-6
    models it always equals `stability`

  With FSRS-7, `stability` is no longer the interval at which retrievability
  drops to 90%. Use `Fsrs.s90/2` for that value.

  中文说明：记忆状态。FSRS-7 新增 `stability_fast`；此时 `stability` 不再等于
  可提取率降到 90% 的间隔，需要该值时用 `Fsrs.s90/2`。
  """

  @enforce_keys [:stability, :difficulty, :stability_fast]
  defstruct [:stability, :difficulty, :stability_fast]

  @type t :: %__MODULE__{
          stability: float(),
          difficulty: float(),
          stability_fast: float()
        }
end

# The negative controls swap sabotaged library modules into the running VM,
# so they never share a run with the rest of the suite: `mix test --only
# controls` runs them on their own (Serialize.ControlsTest).
ExUnit.start(exclude: [:controls])

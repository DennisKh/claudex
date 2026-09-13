defmodule Arithmetix.Tools do
  @moduledoc """
  One tool per arithmetic operation, plus a `finish` tool the model calls when
  it has an answer.

  Each `@doc` is what Claude reads to decide whether to reach for the tool, and
  each `@spec` becomes the JSON schema for its arguments.
  """

  use Claudex.Tool

  @doc """
  Perform an arithmetic operation of addition of two numbers. Returns a number.
  """
  @tool true
  @spec add(a :: number(), b :: number()) :: number()
  def add(a, b), do: a + b

  @doc """
  Perform an arithmetic operation of subtraction of two numbers. Returns a number.
  """
  @tool true
  @spec subtract(a :: number(), b :: number()) :: number()
  def subtract(a, b), do: a - b

  @doc """
  Perform an arithmetic operation of multiplication of two numbers. Returns a number.
  """
  @tool true
  @spec multiply(a :: number(), b :: number()) :: number()
  def multiply(a, b), do: a * b

  @doc """
  Perform an arithmetic operation of division of two numbers. Returns an number.
  """
  @tool true
  @spec divide(a :: number(), b :: number()) :: number()
  def divide(a, b) do
    if b == 0, do: raise(Claudex.Tool.Error, "it's not allowed to divide by 0")

    a / b
  end

  @doc """
  Call when ALL calculations are done. `final_result` is the final
  numerical answer, computed via tools.
  """
  @tool true
  @spec finish(summary :: String.t(), final_result :: number() | nil) :: String.t()
  def finish(summary, final_result) do
    "FINISHED (result=#{final_result}): #{summary}"
  end
end

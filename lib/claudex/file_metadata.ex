defmodule Claudex.FileMetadata do
  @moduledoc """
  The Files API's record of one stored file: its id, filename, MIME type,
  size, and timestamps. `Claudex.Files` returns these, one from `upload/3` and
  a page of them from `list/2`.

  `downloadable` is false for anything you uploaded — only files Claude
  creates, through skills or the code execution tool, can be downloaded.
  `expires_at` is nil unless the file was uploaded with an expiry.
  """

  alias Claudex.Timestamp

  defstruct [
    :id,
    :type,
    :filename,
    :mime_type,
    :size_bytes,
    :created_at,
    :expires_at,
    :downloadable
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          filename: String.t(),
          mime_type: String.t(),
          size_bytes: non_neg_integer(),
          created_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          downloadable: boolean() | nil
        }

  @doc false
  @spec decode(map()) :: t()
  def decode(json) do
    %__MODULE__{
      id: json["id"],
      type: json["type"],
      filename: json["filename"],
      mime_type: json["mime_type"],
      size_bytes: json["size_bytes"],
      created_at: Timestamp.decode(json["created_at"]),
      expires_at: Timestamp.decode(json["expires_at"]),
      downloadable: json["downloadable"]
    }
  end
end

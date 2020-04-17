defmodule Explorer.GraphQL do
  @moduledoc """
  The GraphQL context.
  """

  import Ecto.Query,
    only: [
      from: 2,
      union_all: 2,
      order_by: 3,
      or_where: 3,
      subquery: 1,
      where: 3
    ]

  alias Explorer.Chain.{
    Address,
    Block,
    CeloAccount,
    CeloClaims,
    Hash,
    InternalTransaction,
    Token,
    TokenTransfer,
    Transaction
  }

  alias Explorer.{Chain, Repo}

  alias Explorer.Chain.Address.CoinBalance

  @doc """
  Returns a query to fetch transactions with a matching `to_address_hash`,
  `from_address_hash`, or `created_contract_address_hash` field for a given address hash.

  Orders transactions by descending block number and index.
  """
  @spec address_to_transactions_query(Hash.Address.t()) :: Ecto.Query.t()
  def address_to_transactions_query(address_hash) do
    Transaction
    |> order_by([transaction], desc: transaction.block_number, desc: transaction.index)
    |> where([transaction], transaction.to_address_hash == ^address_hash)
    |> or_where([transaction], transaction.from_address_hash == ^address_hash)
    |> or_where([transaction], transaction.created_contract_address_hash == ^address_hash)
  end

  def address_to_account_query(address_hash) do
    CeloAccount
    |> where([account], account.address == ^address_hash)
  end

  def address_to_validator_query(address_hash) do
    Chain.celo_validator_query()
    |> where([account], account.address == ^address_hash)
  end

  def address_to_affiliates_query(address_hash) do
    Chain.celo_validator_query()
    |> where([account], account.group_address_hash == ^address_hash)
  end

  def address_to_claims_query(address_hash) do
    CeloClaims
    |> where([account], account.address == ^address_hash)
  end

  def address_to_validator_group_query(address_hash) do
    Chain.celo_validator_group_query()
    |> where([account], account.address == ^address_hash)
  end

  def address_query(address_hash) do
    Address
    |> where([account], account.hash == ^address_hash)
  end

  @doc """
  Returns an internal transaction for a given transaction hash and index.
  """
  @spec get_internal_transaction(map()) :: {:ok, InternalTransaction.t()} | {:error, String.t()}
  def get_internal_transaction(%{transaction_hash: _, index: _} = clauses) do
    if internal_transaction = Repo.get_by(InternalTransaction.where_nonpending_block(), clauses) do
      {:ok, internal_transaction}
    else
      {:error, "Internal transaction not found."}
    end
  end

  @doc """
  Returns a query to fetch internal transactions for a given transaction.

  Orders internal transactions by ascending index.
  """
  @spec transaction_to_internal_transactions_query(Transaction.t()) :: Ecto.Query.t()
  def transaction_to_internal_transactions_query(%Transaction{
        hash: %Hash{byte_count: unquote(Hash.Full.byte_count())} = hash
      }) do
    query =
      from(
        it in InternalTransaction,
        inner_join: t in assoc(it, :transaction),
        order_by: [asc: it.index],
        where: it.transaction_hash == ^hash,
        select: it
      )

    query
    |> InternalTransaction.where_nonpending_block()
    |> Chain.where_transaction_has_multiple_internal_transactions()
  end

  @doc """
  Returns a token transfer for a given transaction hash and log index.
  """
  @spec get_token_transfer(map()) :: {:ok, TokenTransfer.t()} | {:error, String.t()}
  def get_token_transfer(%{transaction_hash: _, log_index: _} = clauses) do
    if token_transfer = Repo.get_by(TokenTransfer, clauses) do
      {:ok, token_transfer}
    else
      {:error, "Token transfer not found."}
    end
  end

  @doc """
  Returns a query to fetch token transfers for a token contract address hash.

  Orders token transfers by descending block number, descending transaction index, and ascending log index.
  """
  @spec list_token_transfers_query(Hash.t()) :: Ecto.Query.t()
  def list_token_transfers_query(%Hash{byte_count: unquote(Hash.Address.byte_count())} = token_contract_address_hash) do
    from(
      tt in TokenTransfer,
      inner_join: t in assoc(tt, :transaction),
      where: tt.token_contract_address_hash == ^token_contract_address_hash,
      order_by: [desc: tt.block_number, desc: t.index, asc: tt.log_index],
      select: tt
    )
  end

  def list_gold_transfers_query do
    tt_query =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cGLD",
        select: %{
          transaction_hash: tt.transaction_hash,
          from_address_hash: tt.from_address_hash,
          to_address_hash: tt.to_address_hash,
          log_index: tt.log_index,
          tx_index: -1,
          index: -1,
          value: tt.amount,
          block_number: tt.block_number
        }
      )

    tx_query =
      from(
        tx in Transaction,
        where: tx.value > ^0,
        select: %{
          transaction_hash: tx.hash,
          from_address_hash: tx.from_address_hash,
          to_address_hash: tx.to_address_hash,
          log_index: 0 - tx.index,
          tx_index: tx.index,
          index: 0 - tx.index,
          value: tx.value,
          block_number: tx.block_number
        }
      )

    internal_query =
      from(
        tx in InternalTransaction,
        where: tx.value > ^0,
        where: tx.call_type != fragment("'delegatecall'"),
        where: tx.index != 0,
        select: %{
          transaction_hash: tx.transaction_hash,
          from_address_hash: tx.from_address_hash,
          to_address_hash: tx.to_address_hash,
          log_index: 0 - tx.index,
          tx_index: 0 - tx.index,
          index: tx.index,
          value: tx.value,
          block_number: tx.block_number
        }
      )

    query =
      tt_query
      |> union_all(^tx_query)
      |> union_all(^internal_query)

    from(tt in subquery(query),
      select: %{
        transaction_hash: tt.transaction_hash,
        from_address_hash: tt.from_address_hash,
        to_address_hash: tt.to_address_hash,
        log_index: tt.log_index,
        tx_index: tt.tx_index,
        index: tt.index,
        value: tt.value,
        block_number: tt.block_number
      },
      order_by: [desc: tt.block_number, desc: tt.tx_index, desc: tt.log_index, desc: tt.index]
    )
  end

  def list_gold_transfers_query_for_address(address_hash) do
    list_gold_transfers_query()
    |> where([t], t.from_address_hash == ^address_hash or t.to_address_hash == ^address_hash)
  end

  def txtransfers_query_for_address(address_hash) do
    txtransfers_query()
    |> where([t], t.address_hash == ^address_hash)
  end

  def celo_tx_transfers_query_by_txhash(tx_hash) do
    celo_tx_transfers_query()
    |> where([t], t.transaction_hash == ^tx_hash)
  end

  def txtransfers_query do
    tt_query =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cGLD",
        select: %{
          transaction_hash: tt.transaction_hash,
          address_hash: tt.from_address_hash
        }
      )

    tt_query2 =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cGLD",
        select: %{
          transaction_hash: tt.transaction_hash,
          address_hash: tt.to_address_hash
        }
      )

    usd_query =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cUSD",
        select: %{
          transaction_hash: tt.transaction_hash,
          address_hash: tt.from_address_hash
        }
      )

    usd_query2 =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cUSD",
        select: %{
          transaction_hash: tt.transaction_hash,
          address_hash: tt.to_address_hash
        }
      )

    tx_query =
      from(
        tx in Transaction,
        where: tx.value > ^0,
        select: %{
          transaction_hash: tx.hash,
          address_hash: tx.from_address_hash
        }
      )

    tx_query2 =
      from(
        tx in Transaction,
        where: tx.value > ^0,
        select: %{
          transaction_hash: tx.hash,
          address_hash: tx.to_address_hash
        }
      )

    internal_query =
      from(
        tx in InternalTransaction,
        where: tx.value > ^0,
        where: tx.call_type != fragment("'delegatecall'"),
        where: tx.index != 0,
        select: %{
          transaction_hash: tx.transaction_hash,
          address_hash: tx.from_address_hash
        }
      )

    internal_query2 =
      from(
        tx in InternalTransaction,
        where: tx.value > ^0,
        where: tx.call_type != fragment("'delegatecall'"),
        where: tx.index != 0,
        select: %{
          transaction_hash: tx.transaction_hash,
          address_hash: tx.to_address_hash
        }
      )

    query =
      tt_query
      |> union_all(^tx_query)
      |> union_all(^usd_query)
      |> union_all(^internal_query)
      |> union_all(^tt_query2)
      |> union_all(^tx_query2)
      |> union_all(^usd_query2)
      |> union_all(^internal_query2)

    from(tt in subquery(query),
      select: %{
        transaction_hash: tt.transaction_hash,
        address_hash: tt.address_hash
      }
    )
  end

  def celo_tx_transfers_query do
    tt_query =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cGLD",
        select: %{
          transaction_hash: tt.transaction_hash,
          from_address_hash: tt.from_address_hash,
          to_address_hash: tt.to_address_hash,
          log_index: tt.log_index,
          tx_index: -1,
          index: -1,
          value: tt.amount,
          usd_value: 0,
          block_number: tt.block_number
        }
      )

    usd_query =
      from(
        tt in TokenTransfer,
        join: t in Token,
        where: tt.token_contract_address_hash == t.contract_address_hash,
        where: t.symbol == "cUSD",
        select: %{
          transaction_hash: tt.transaction_hash,
          from_address_hash: tt.from_address_hash,
          to_address_hash: tt.to_address_hash,
          log_index: tt.log_index,
          tx_index: 0 - tt.log_index,
          index: 0 - tt.log_index,
          value: 0 - tt.amount,
          usd_value: tt.amount,
          block_number: tt.block_number
        }
      )

    tx_query =
      from(
        tx in Transaction,
        where: tx.value > ^0,
        select: %{
          transaction_hash: tx.hash,
          from_address_hash: tx.from_address_hash,
          to_address_hash: tx.to_address_hash,
          log_index: 0 - tx.index,
          tx_index: tx.index,
          index: 0 - tx.index,
          value: tx.value,
          usd_value: 0 - tx.value,
          block_number: tx.block_number
        }
      )

    internal_query =
      from(
        tx in InternalTransaction,
        where: tx.value > ^0,
        where: tx.call_type != fragment("'delegatecall'"),
        where: tx.index != 0,
        select: %{
          transaction_hash: tx.transaction_hash,
          from_address_hash: tx.from_address_hash,
          to_address_hash: tx.to_address_hash,
          log_index: 0 - tx.index,
          tx_index: 0 - tx.index,
          index: tx.index,
          value: tx.value,
          usd_value: 0 - tx.value,
          block_number: tx.block_number
        }
      )

    query =
      tt_query
      |> union_all(^usd_query)
      |> union_all(^tx_query)
      |> union_all(^internal_query)

    from(tt in subquery(query),
      select: %{
        transaction_hash: tt.transaction_hash,
        from_address_hash: tt.from_address_hash,
        to_address_hash: tt.to_address_hash,
        log_index: tt.log_index,
        tx_index: tt.tx_index,
        index: tt.index,
        value: tt.value,
        usd_value: fragment("greatest(0, ?)", tt.usd_value),
        block_number: tt.block_number
      },
      order_by: [desc: tt.block_number, desc: tt.tx_index, desc: tt.log_index, desc: tt.index]
    )
  end

  def list_coin_balances_query(address_hash) do
    from(
      cb in CoinBalance,
      where: cb.address_hash == ^address_hash,
      where: not is_nil(cb.value),
      inner_join: b in Block,
      on: cb.block_number == b.number,
      order_by: [desc: :block_number],
      select_merge: %{delta: fragment("value - coalesce(lag(value, 1) over (order by block_number), 0)")},
      select_merge: %{block_timestamp: b.timestamp}
    )
  end
end

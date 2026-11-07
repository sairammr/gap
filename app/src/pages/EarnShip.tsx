/* ============================================================================
   Ship a quote — the maker side, as an action rather than a script.

   WHY THIS CAN EXIST AT ALL. Aqua keys balances by `msg.sender`
   (`_balances[msg.sender][app][strategyHash][token]`) and SwapVM reads them back
   with `AQUA.safeBalances(order.maker, ...)`. `order.maker` is the WeekendDesk
   contract, so the ship has to originate from the desk. `script/ShipAsk.s.sol`
   only prints calldata because the EOA running it is not the desk — but
   `WeekendDesk.ship` is `onlyOwner` and forwards to `AQUA.ship`, so the desk's
   OWNER can ship through the desk from a wallet. That is this panel.

   Everything below the owner gate is the same pre-flight the script runs, in the
   same order, because each one of these maps to a revert that is expensive to
   read after the fact:

     ZeroShipAmount          a cap of zero is an order that can never fill
     NotAPair                equal tokens are not a tradeable pair
     PremiumFloorInversion   the order prices under the floor `buyOption` enforces,
                             so fills revert mid-transaction inside preTransferOut
                             with nothing naming the cause
     HashDrift               locally-derived hash != router.hash(order); the shipped
                             balances would key a hash no fill can reach
     AlreadyShipped          strategies are IMMUTABLE — re-shipping a hash reverts,
                             which is why the salt is fresh per ship and never implicit

   Shipping is irreversible in one direction: the amount can only be raised by a
   later ship of the same hash, and `dock` is the only way back out.
   ========================================================================= */

import { useCallback, useEffect, useMemo, useState } from 'react'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { encodeAbiParameters, formatUnits, keccak256, parseUnits } from 'viem'
import { Anchor, RefreshCw, ShieldAlert } from 'lucide-react'
import { aquaAbi, deskAbi, orderAbiParam, routerAbi } from '../lib/abi'
import { buildOrder, SIDE, type Hex, type Order } from '../lib/orders'
import { QUOTE_DECIMALS, UNDERLYING_DECIMALS } from '../lib/strategy'
import type { Deployment } from '../lib/deployment'
import { Alert, Badge, Button, Field, Input, KeyValue, Panel, Segmented } from '../ui'

export interface EarnShipProps {
  deployment: Deployment | null
  deployed: boolean
  onToast: (msg: string) => void
}

type Side = 'ask' | 'bid'

/** One pre-flight result. `ok: null` means "not checked yet". */
interface Check {
  label: string
  ok: boolean | null
  detail: string
}

/** A fresh bytes32. A reused salt is the one thing that makes a ship unrepeatable. */
function freshSalt(): Hex {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return `0x${Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')}` as Hex
}

export function EarnShip({ deployment, deployed, onToast }: EarnShipProps) {
  const { address, isConnected } = useAccount()
  const publicClient = usePublicClient()
  const { writeContractAsync, isPending } = useWriteContract()

  const [owner, setOwner] = useState<Hex | null>(null)
  const [floorBps, setFloorBps] = useState<number | null>(null)

  const [side, setSide] = useState<Side>('ask')
  const [seriesId, setSeriesId] = useState('0')
  const [ivPct, setIvPct] = useState('60')
  const [minPremiumBps, setMinPremiumBps] = useState('25')
  const [amount, setAmount] = useState('1')
  const [days, setDays] = useState('7')
  const [salt, setSalt] = useState<Hex>(freshSalt)

  const [checks, setChecks] = useState<Check[]>([])
  const [checking, setChecking] = useState(false)
  const [hash, setHash] = useState<Hex | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const isOwner = !!owner && !!address && owner.toLowerCase() === address.toLowerCase()

  // The option token is per-series, so the series picker drives it. Only the two
  // series the deployment knows about can be shipped from here.
  const optionToken = useMemo(() => {
    if (!deployment) return null
    if (Number(seriesId) === deployment.shortSeriesId) return deployment.shortOptionToken as Hex
    if (Number(seriesId) === deployment.seriesId) return deployment.optionToken as Hex
    return null
  }, [deployment, seriesId])

  useEffect(() => {
    if (!deployed || !deployment?.desk || !publicClient) return
    let cancelled = false
    void (async () => {
      try {
        const [o, strat] = await Promise.all([
          publicClient.readContract({
            address: deployment.desk as Hex,
            abi: deskAbi,
            functionName: 'owner',
          }) as Promise<Hex>,
          publicClient.readContract({
            address: deployment.desk as Hex,
            abi: deskAbi,
            functionName: 'ownStrategy',
          }) as Promise<{ minPremiumBps: number }>,
        ])
        if (cancelled) return
        setOwner(o)
        setFloorBps(Number(strat.minPremiumBps))
      } catch (e) {
        if (!cancelled) setErr(e instanceof Error ? e.message : String(e))
      }
    })()
    return () => {
      cancelled = true
    }
  }, [deployed, deployment?.desk, publicClient])

  /** The order these inputs describe, or the reason they do not describe one. */
  const built = useMemo((): { order: Order; bytes: Hex } | { error: string } => {
    if (!deployment || !optionToken) return { error: 'No deployment, or unknown series.' }
    try {
      const order = buildOrder({
        desk: deployment.desk as Hex,
        pricer: deployment.pricer as Hex,
        quote: deployment.usdc as Hex,
        optionToken,
        seriesId: BigInt(seriesId || 0),
        volWad: BigInt(Math.round(Number(ivPct || 0) * 1e16)),
        minPremiumBps: Number(minPremiumBps || 0),
        side: side === 'ask' ? SIDE.ASK : SIDE.BID,
        deadline: Math.floor(Date.now() / 1000) + Number(days || 0) * 86400,
        salt,
        minRateA: 0n,
        minRateB: 0n,
      })
      const bytes = encodeAbiParameters([orderAbiParam], [order]) as Hex
      return { order, bytes }
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) }
    }
  }, [deployment, optionToken, seriesId, ivPct, minPremiumBps, side, days, salt])

  /** ASK ships the option cap, BID ships the USDC budget. The other leg is ALWAYS
   *  present at zero: `safeBalances` reverts unless both tokens sit in an active
   *  strategy, and that zero leg is a lookup, never a budget. */
  const legs = useMemo(() => {
    if (!deployment || !optionToken) return null
    const isAsk = side === 'ask'
    const dp = isAsk ? UNDERLYING_DECIMALS : QUOTE_DECIMALS
    let amt: bigint
    try {
      amt = parseUnits(amount || '0', dp)
    } catch {
      return null
    }
    const quote = deployment.usdc as Hex
    return {
      tokens: (isAsk ? [optionToken, quote] : [quote, optionToken]) as Hex[],
      amounts: [amt, 0n],
      fundedToken: (isAsk ? optionToken : quote) as Hex,
      fundedAmount: amt,
      dp,
      symbol: isAsk ? 'options' : 'USDC',
    }
  }, [deployment, optionToken, side, amount])

  const runChecks = useCallback(async () => {
    if (!deployment || !publicClient || !legs || 'error' in built) {
      setErr('error' in built ? built.error : 'Not ready.')
      return
    }
    setChecking(true)
    setErr(null)
    const out: Check[] = []
    try {
      const localHash = keccak256(built.bytes)
      setHash(localHash)

      out.push({
        label: 'Ship amount is non-zero',
        ok: legs.fundedAmount > 0n,
        detail:
          legs.fundedAmount > 0n
            ? `${formatUnits(legs.fundedAmount, legs.dp)} ${legs.symbol}`
            : 'A cap of zero is an order that can never fill.',
      })

      out.push({
        label: 'Quote and option token are a pair',
        ok: legs.tokens[0].toLowerCase() !== legs.tokens[1].toLowerCase(),
        detail: `${legs.tokens[0].slice(0, 10)}… / ${legs.tokens[1].slice(0, 10)}…`,
      })

      const bps = Number(minPremiumBps || 0)
      out.push({
        label: 'Premium floor is not inverted',
        ok: floorBps == null ? null : bps >= floorBps,
        detail:
          floorBps == null
            ? "Could not read the desk's own strategy floor."
            : bps >= floorBps
              ? `order ${bps} bps ≥ core floor ${floorBps} bps`
              : `order ${bps} bps is BELOW the core's ${floorBps} bps — fills would revert mid-transaction with PremiumBelowFloor.`,
      })

      const onchainHash = (await publicClient.readContract({
        address: deployment.swapVmRouter as Hex,
        abi: routerAbi,
        functionName: 'hash',
        args: [built.order],
      })) as Hex
      const hashOk = onchainHash.toLowerCase() === localHash.toLowerCase()
      out.push({
        label: 'router.hash(order) matches the local hash',
        ok: hashOk,
        detail: hashOk ? localHash : `router says ${onchainHash}, we derived ${localHash}`,
      })

      // Strategies are immutable. A hash with balances already on it cannot be
      // re-shipped, which is what the fresh salt is for.
      const [bal] = (await publicClient.readContract({
        address: deployment.aqua as Hex,
        abi: aquaAbi,
        functionName: 'rawBalances',
        args: [deployment.desk as Hex, deployment.swapVmRouter as Hex, localHash, legs.fundedToken],
      })) as [bigint, number]
      out.push({
        label: 'This strategy hash is unshipped',
        ok: bal === 0n,
        detail:
          bal === 0n
            ? 'No balance on this hash yet.'
            : `Already carries ${formatUnits(bal, legs.dp)} — strategies are immutable. Regenerate the salt.`,
      })

      setChecks(out)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
      setChecks(out)
    } finally {
      setChecking(false)
    }
  }, [deployment, publicClient, legs, built, minPremiumBps, floorBps])

  const allClear = checks.length > 0 && checks.every((c) => c.ok === true)

  const onShip = useCallback(async () => {
    if (!deployment || !legs || 'error' in built || !allClear) return
    try {
      // Aqua pulls from the desk at fill time, so the desk has to have approved it.
      // Owner-only, and routed through the desk for the same reason the ship is.
      await writeContractAsync({
        address: deployment.desk as Hex,
        abi: deskAbi,
        functionName: 'approveAqua',
        args: [legs.fundedToken, legs.fundedAmount],
      })
      const tx = await writeContractAsync({
        address: deployment.desk as Hex,
        abi: deskAbi,
        functionName: 'ship',
        args: [deployment.swapVmRouter as Hex, built.bytes, legs.tokens, legs.amounts],
      })
      onToast(`Shipped — ${tx.slice(0, 10)}…`)
      setSalt(freshSalt())
      setChecks([])
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }, [deployment, legs, built, allClear, writeContractAsync, onToast])

  if (!deployed) return null

  return (
    <Panel
      title="Ship a quote"
      icon={<Anchor size={16} />}
      actions={
        isOwner ? (
          <Badge tone="green">desk owner</Badge>
        ) : (
          <Badge tone="outline">read-only</Badge>
        )
      }
    >
      <div className="vx-col">
        {!isOwner && (
          <Alert tone="info" title="Only the desk's owner can ship">
            <p style={{ margin: 0 }}>
              Aqua keys balances by <code>msg.sender</code>, and the maker is the{' '}
              <code>WeekendDesk</code> contract — so the ship has to come from the desk.{' '}
              <code>WeekendDesk.ship</code> is <code>onlyOwner</code> and forwards the call, so the
              owner can do this from a wallet.
              {owner && (
                <>
                  {' '}
                  Owner is <code>{owner}</code>
                  {isConnected && address ? (
                    <>
                      , you are <code>{address}</code>.
                    </>
                  ) : (
                    ' — connect that wallet.'
                  )}
                </>
              )}
            </p>
          </Alert>
        )}

        <div className="vx-grid vx-grid--stats">
          <Field label="Side">
            <Segmented
              value={side}
              onChange={(v) => {
                setSide(v as Side)
                setChecks([])
              }}
              options={[
                { value: 'ask', label: 'Ask · sell options' },
                { value: 'bid', label: 'Bid · buy them back' },
              ]}
            />
          </Field>
          <Field label="Series">
            <Input value={seriesId} onChange={(e) => setSeriesId(e.target.value)} inputMode="numeric" />
          </Field>
          <Field label="IV %">
            <Input value={ivPct} onChange={(e) => setIvPct(e.target.value)} inputMode="decimal" />
          </Field>
          <Field label="Min premium (bps)" hint={floorBps == null ? undefined : `core floor ${floorBps}`}>
            <Input
              value={minPremiumBps}
              onChange={(e) => setMinPremiumBps(e.target.value)}
              inputMode="numeric"
            />
          </Field>
          <Field label={side === 'ask' ? 'Cap (options)' : 'Budget (USDC)'}>
            <Input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
          </Field>
          <Field label="Deadline (days)">
            <Input value={days} onChange={(e) => setDays(e.target.value)} inputMode="numeric" />
          </Field>
        </div>

        <KeyValue
          rows={[
            ['Maker', <code key="m">{deployment?.desk}</code>],
            ['App (ships to)', <code key="a">{deployment?.swapVmRouter}</code>],
            [
              'Salt',
              <span key="s" className="vx-row">
                <code>
                  {salt.slice(0, 18)}…{salt.slice(-6)}
                </code>
                <Button
                  size="sm"
                  variant="ghost"
                  icon={<RefreshCw size={13} />}
                  onClick={() => {
                    setSalt(freshSalt())
                    setChecks([])
                    setHash(null)
                  }}
                >
                  New
                </Button>
              </span>,
            ],
            ['Strategy hash', hash ? <code key="h">{hash}</code> : 'run the pre-flight'],
          ]}
        />

        {checks.length > 0 && (
          <KeyValue
            rows={checks.map((c) => [
              c.label,
              <span key={c.label} style={{ color: c.ok === false ? 'var(--down)' : undefined }}>
                {c.ok === true ? '✓ ' : c.ok === false ? '✗ ' : '— '}
                {c.detail}
              </span>,
            ])}
          />
        )}

        {err && (
          <Alert tone="error" title="Could not complete">
            <code style={{ wordBreak: 'break-all' }}>{err}</code>
          </Alert>
        )}

        {allClear && (
          <Alert tone="warning" title="Shipping is one-way">
            A shipped strategy is immutable — the amount can only be raised by shipping the same
            hash again, and <code>dock</code> is the only way back out. This sends two transactions:{' '}
            <code>approveAqua</code>, then <code>ship</code>.
          </Alert>
        )}

        <div className="vx-row">
          <Button
            variant="secondary"
            icon={<ShieldAlert size={14} />}
            loading={checking}
            onClick={() => void runChecks()}
          >
            Run pre-flight
          </Button>
          <Button
            variant="primary"
            disabled={!isOwner || !allClear}
            loading={isPending}
            onClick={() => void onShip()}
          >
            Ship
          </Button>
        </div>
      </div>
    </Panel>
  )
}

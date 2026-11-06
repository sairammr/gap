/* ============================================================================
   Earn — be the maker.

   Shipping collateral into 1inch Aqua used to live only in contracts/script/
   Ship.s.sol, which hid the most interesting property of the system: `ship` does
   not move a single token. It writes an allowance-like entry on Aqua's books
   against the maker's own wallet, and the ERC-20 only moves at `pull` time, when
   a buyer actually turns up. So the two numbers this view puts side by side —
   what Aqua thinks is committed, and what the wallet actually holds — can
   disagree, and when they do, `buyOption` reverts for everyone.

   Contract surface used here: usdc.approve, AQUA.ship, AQUA.rawBalances,
   GapOptionsApp.hashStrategy. Nothing new.
   ========================================================================= */

import { useCallback, useEffect, useState } from 'react'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { encodeAbiParameters, formatUnits, parseUnits } from 'viem'
import { AlertTriangle, Anchor, Moon, Sun, Wallet } from 'lucide-react'
import { aquaAbi, erc20Abi, gapOptionsAppAbi, strategyAbiParams } from '../lib/abi'
import { buildStrategy, DEFAULT_VOL, QUOTE_DECIMALS } from '../lib/strategy'
import { CLOSED_VOL_MULTIPLIER, marketClosed, suggestedVol } from '../lib/session'
import type { Deployment } from '../lib/deployment'
import {
  Alert,
  Badge,
  Button,
  Card,
  WakeSlider,
  Field,
  Input,
  KeyValue,
  Panel,
  StatCard,
} from '../ui'

export interface EarnProps {
  deployment: Deployment | null
  deployed: boolean
  onToast: (msg: string) => void
}

interface MakerBooks {
  /** AQUA.rawBalances — what the app is allowed to pull for this strategy. */
  committed: number
  /** The ERC-20 the pull would actually come out of. */
  wallet: number
  strategyHash: `0x${string}`
}

export function Earn({ deployment, deployed, onToast }: EarnProps) {
  const { address, isConnected } = useAccount()
  const publicClient = usePublicClient()
  const { writeContractAsync, isPending } = useWriteContract()

  const [amount, setAmount] = useState('1000')
  const [vol, setVol] = useState(DEFAULT_VOL)
  const [books, setBooks] = useState<MakerBooks | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [nonce, setNonce] = useState(0) // bump to re-read after a ship

  const closed = marketClosed()
  const hint = suggestedVol(DEFAULT_VOL)
  const hintTaken = Math.abs(vol - hint) < 1e-9

  // The connected wallet IS the maker here — the one place in the app where the
  // Strategy's maker is not read off the deployment JSON.
  const canRead = deployed && !!deployment?.aqua && !!address && !!publicClient
  const strategy =
    deployment && address
      ? buildStrategy(deployment, { address, volWad: parseUnits(vol.toFixed(2), 18).toString() })
      : null

  const refresh = useCallback(async () => {
    if (!canRead || !deployment || !address || !publicClient || !strategy) return
    try {
      const strategyHash = (await publicClient.readContract({
        address: deployment.gapOptionsApp as `0x${string}`,
        abi: gapOptionsAppAbi,
        functionName: 'hashStrategy',
        args: [strategy],
      })) as `0x${string}`
      const [raw, wallet] = await Promise.all([
        publicClient.readContract({
          address: deployment.aqua as `0x${string}`,
          abi: aquaAbi,
          functionName: 'rawBalances',
          args: [address, deployment.gapOptionsApp as `0x${string}`, strategyHash, deployment.usdc as `0x${string}`],
        }) as Promise<readonly [bigint, number]>,
        publicClient.readContract({
          address: deployment.usdc as `0x${string}`,
          abi: erc20Abi,
          functionName: 'balanceOf',
          args: [address],
        }) as Promise<bigint>,
      ])
      setBooks({
        committed: Number(formatUnits(raw[0], QUOTE_DECIMALS)),
        wallet: Number(formatUnits(wallet, QUOTE_DECIMALS)),
        strategyHash,
      })
      setErr(null)
    } catch (e) {
      setBooks(null)
      setErr(e instanceof Error ? e.message.split('\n')[0] : 'Aqua read failed')
    }
    // `strategy` is rebuilt every render; the values that matter are in the deps.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [canRead, deployment, address, publicClient, vol])

  useEffect(() => {
    void refresh()
  }, [refresh, nonce])

  const amountNum = Number(amount)
  const amountValid = Number.isFinite(amountNum) && amountNum > 0
  const underfunded = !!books && books.committed > 0 && books.wallet < books.committed
  const shipUnderfunded = amountValid && !!books && books.wallet < amountNum

  async function handleShip() {
    if (!deployment || !address || !publicClient || !strategy || !amountValid) return
    setErr(null)
    const aqua = deployment.aqua as `0x${string}`
    const usdc = deployment.usdc as `0x${string}`
    const amountWei = parseUnits(amount, QUOTE_DECIMALS)
    try {
      // Aqua pulls from the maker's wallet at `pull` time, so it needs the ERC-20
      // allowance now even though `ship` itself transfers nothing.
      const allowance = (await publicClient.readContract({
        address: usdc,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [address, aqua],
      })) as bigint
      if (allowance < amountWei) {
        onToast('Approving USDC for Aqua…')
        const hash = await writeContractAsync({
          address: usdc,
          abi: erc20Abi,
          functionName: 'approve',
          args: [aqua, amountWei],
        })
        await publicClient.waitForTransactionReceipt({ hash })
      }
      onToast('Shipping collateral into Aqua…')
      const hash = await writeContractAsync({
        address: aqua,
        abi: aquaAbi,
        functionName: 'ship',
        args: [
          deployment.gapOptionsApp as `0x${string}`,
          encodeAbiParameters(strategyAbiParams, [strategy]),
          [usdc],
          [amountWei],
        ],
      })
      await publicClient.waitForTransactionReceipt({ hash })
      onToast(`Shipped ${amount} USDC — you are now quoting at ${(vol * 100).toFixed(0)}% IV`)
      setNonce((n) => n + 1)
    } catch (e) {
      setErr(e instanceof Error ? e.message.split('\n')[0] : 'ship failed')
    }
  }

  async function mintTestUsdc() {
    if (!deployment?.usdc || !address) return
    await writeContractAsync({
      address: deployment.usdc as `0x${string}`,
      abi: erc20Abi,
      functionName: 'mint',
      args: [address, parseUnits('10000', QUOTE_DECIMALS)],
    })
    onToast('Minted 10,000 test USDC')
    setNonce((n) => n + 1)
  }

  return (
    <div className="vx-grid vx-grid--desk">
      <div className="vx-col">
        <Panel
          title="Write options, keep your tokens"
          icon={<Anchor size={16} />}
          footer={
            <>
              Collateral and premium both move through <strong>1inch Aqua</strong>:{' '}
              <code>ship</code> registers the commitment, <code>pull</code> draws the cap backing out
              of your wallet when a buy lands, and <code>push</code> deposits the buyer&rsquo;s
              premium back into your Aqua balance. The app never custodies anything.
            </>
          }
        >
          <div className="vx-col">
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              Shipping commits USDC to back the options you write. <b>The tokens stay in your
              wallet</b>, under an Aqua entry — they only move when someone actually buys, and only
              up to the cap of the option they bought.
            </p>
            <p style={{ margin: 0, font: 'var(--t-body-l)', color: 'var(--ink-soft)' }}>
              Every option is fully collateralised at <code>cap × size</code>, so you can never be
              liquidated either. You keep the premium; you pay out at most the cap.
            </p>
          </div>
        </Panel>

        <div className="vx-grid vx-grid--stats">
          <StatCard
            pair="Committed on Aqua"
            color="#7b61ff"
            value={books ? books.committed.toFixed(2) : '—'}
            sub="rawBalances(you, app, strategy, USDC)"
          />
          <StatCard
            pair="Actually in your wallet"
            color={underfunded ? '#ef4444' : '#22c55e'}
            value={books ? books.wallet.toFixed(2) : '—'}
            sub="USDC.balanceOf(you) — what a pull really draws from"
          />
        </div>

        {underfunded && (
          <Alert tone="error" title="Your Aqua books overstate your wallet">
            Aqua says <b>{books!.committed.toFixed(2)} USDC</b> is committed, but your wallet holds{' '}
            <b>{books!.wallet.toFixed(2)} USDC</b>. <code>ship</code> is only an accounting entry —
            the transfer happens at <code>pull</code> time, out of this wallet. Any buy whose{' '}
            <code>cap × size</code> exceeds the wallet balance will revert, and the taker eats the
            failed transaction. Top the wallet back up or dock the strategy.
          </Alert>
        )}

        {books && !underfunded && books.committed > 0 && (
          <Alert tone="success" title="Backing is real">
            Committed and held match: anything inside <b>{books.committed.toFixed(2)} USDC</b> of cap
            backing can be pulled without reverting.
          </Alert>
        )}

        {books && (
          <Panel title="Your strategy" icon={<Wallet size={16} />}>
            <KeyValue
              rows={[
                ['Maker', address ?? '—'],
                ['Strategy hash', <code key="h">{books.strategyHash}</code>],
                ['Implied vol', `${(vol * 100).toFixed(0)}%`],
                ['Collateral token', 'USDC (the quote) — NVDAx is pricing-only'],
                ['Session', closed ? 'US equities closed' : 'US equities open'],
              ]}
            />
          </Panel>
        )}
      </div>

      <div className="vx-col">
        <Card>
          <div className="vx-panel__head">
            <div className="vx-panel__title">
              <Anchor size={16} /> Ship collateral
            </div>
            <Badge tone={closed ? 'amber' : 'teal'} icon={closed ? <Moon size={12} /> : <Sun size={12} />}>
              {closed ? 'market closed' : 'market open'}
            </Badge>
          </div>
          <div className="vx-panel__body vx-col">
            <Field
              label="Amount to commit"
              hint="Stays in your wallet. Aqua can pull up to this much, only against options you wrote."
              aside={
                books ? <Badge tone="outline">wallet {books.wallet.toFixed(2)}</Badge> : undefined
              }
              htmlFor="ship-amount"
            >
              <Input
                id="ship-amount"
                type="number"
                min={0}
                step={100}
                mono
                inputSize="lg"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                trailing="USDC"
                invalid={!amountValid}
              />
            </Field>

            <WakeSlider
              label="Your implied vol"
              value={vol}
              onChange={(v: number) => setVol(Math.round(v * 100) / 100)}
              min={0.1}
              max={2}
              step={0.05}
              format={(v: number) => `${(v * 100).toFixed(0)}% IV`}
              scale={['10%', '50%', '100%', '200%']}
              aside={<Badge tone="violet">the axis makers compete on</Badge>}
            />

            <p style={{ margin: 0, font: 'var(--t-body-s)', color: 'var(--muted)' }}>
              <code>quotePremium</code> ignores who the maker is — <code>volWad</code> is the only
              field that changes the price. Quote low and you win flow and carry the risk; quote high
              and you get skipped.
            </p>

            {closed && !hintTaken && (
              <Alert tone="info" title={`Market is closed — consider ${(hint * 100).toFixed(0)}% IV`}>
                The gap this product is named after happens while the market is shut, and none of it
                shows up in the open-hours vol. Weekend Options scales by ×
                {CLOSED_VOL_MULTIPLIER} out of session.{' '}
                <Button size="sm" onClick={() => setVol(Math.round(hint * 100) / 100)}>
                  Use {(hint * 100).toFixed(0)}%
                </Button>
              </Alert>
            )}

            {shipUnderfunded && (
              <Alert tone="warning" title="You are committing more than you hold">
                Aqua will accept this — <code>ship</code> moves nothing. But the first buy large
                enough to need the missing USDC will revert at <code>pull</code>.
              </Alert>
            )}

            <Button
              variant="primary"
              block
              size="lg"
              loading={isPending}
              disabled={!canRead || !isConnected || !amountValid}
              title={!canRead ? 'needs a live deployment and a connected wallet' : undefined}
              onClick={handleShip}
              icon={<Anchor size={15} />}
            >
              Ship {amountValid ? Number(amount).toLocaleString() : '—'} USDC into Aqua
            </Button>

            {deployed && isConnected && (
              <Button size="sm" block onClick={mintTestUsdc}>
                Get 10,000 test USDC
              </Button>
            )}

            {!isConnected && (
              <Alert tone="info" title="Connect a wallet">
                The Earn view writes as <em>you</em> — the connected wallet is the maker.
              </Alert>
            )}

            {err && (
              <Alert tone="error" title="Aqua call failed">
                <code>{err}</code>
                <div style={{ marginTop: 6 }}>
                  <AlertTriangle size={12} /> Aqua strategies are immutable: re-shipping the exact
                  same strategy reverts. Move your vol to write a new one.
                </div>
              </Alert>
            )}
          </div>
          <div className="vx-panel__foot">
            <code>AQUA.ship(app, abi.encode(strategy), [USDC], [amount])</code> — the same call{' '}
            <code>script/Ship.s.sol</code> makes, with your wallet as the maker and your vol in{' '}
            <code>volWad</code>.
          </div>
        </Card>
      </div>
    </div>
  )
}

/* ============================================================================
   The UI kit, laid out as the reference board is. Open with #kit.
   Every control here is the same component the desk uses — this page is the
   spec and the smoke test in one.
   ========================================================================= */

import { useState } from 'react'
import {
  Activity,
  BarChart3,
  Bell,
  Calendar,
  CircleHelp,
  Gift,
  MoreHorizontal,
  Plus,
  Star,
  Wallet,
  ArrowLeftRight,
  CheckCircle2,
  Flame,
  TrendingUp,
  Inbox,
} from 'lucide-react'
import {
  ActivityList,
  Alert,
  Backdrop,
  Badge,
  Button,
  Card,
  Delta,
  EmptyState,
  Field,
  IconButton,
  Input,
  KeyValue,
  Ladder,
  MarketStrip,
  Modal,
  Panel,
  Progress,
  QuickPills,
  Rail,
  SearchInput,
  SectionLabel,
  Segmented,
  Select,
  TopNav,
  Skeleton,
  Sparkline,
  Spinner,
  StatCard,
  Table,
  Tabs,
  Tiles,
  TokenDot,
  Tooltip,
  WakeSlider,
} from '../ui'

const BRAND = [
  ['#14ccbb', 'brand-teal'],
  ['#ffb020', 'brand-amber'],
  ['#7b61ff', 'brand-violet'],
  ['#22c55e', 'brand-green'],
  ['#ef4444', 'brand-red'],
] as const

const NEUTRAL = [
  ['#0f172a', '900'],
  ['#334155', '700'],
  ['#64748b', '500'],
  ['#cbd5e1', '300'],
  ['#e2e8f0', '200'],
  ['#f1f5f9', '100'],
  ['#ffffff', '50'],
] as const

const TYPE = [
  ['Display', '44 / 52', 'Bold'],
  ['H1 Heading', '28 / 36', 'Semi Bold'],
  ['H2 Heading', '20 / 28', 'Semi Bold'],
  ['H3 Heading', '16 / 24', 'Medium'],
  ['Body Large', '14 / 22', 'Regular'],
  ['Body Default', '14 / 20', 'Regular'],
  ['Body Small', '12 / 18', 'Regular'],
  ['Caption', '11 / 16', 'Regular'],
] as const

const RADII = [8, 12, 16, 20, 24, 32, 40]
const SHADOWS = [
  ['XS', 'var(--sh-xs)'],
  ['SM', 'var(--sh-sm)'],
  ['MD', 'var(--sh-md)'],
  ['LG', 'var(--sh-lg)'],
  ['XL', 'var(--sh-xl)'],
] as const

const MARKETS = [
  { pair: 'BTC/USDT', color: '#f7931a', value: '97,417.05', sub: '$ 97,417.05', change: 8.74 },
  { pair: 'ETH/USDT', color: '#627eea', value: '3,865.12', sub: '$ 3,865.12', change: 1.39 },
  { pair: 'SOL/USDT', color: '#14f195', value: '229.56', sub: '$ 229.56', change: 2.81 },
  { pair: 'MATIC/USDT', color: '#8247e5', value: '0.72', sub: '$ 0.72', change: -7.12 },
  { pair: 'TUSD/USDT', color: '#1ec9a0', value: '1.02', sub: '$ 1.02', change: 0.72 },
]

const wave = (n: number, seed: number) =>
  Array.from({ length: n }, (_, i) => Math.sin(i / 2.2 + seed) * 10 + Math.sin(i / 5) * 6 + 50)

export default function Kit() {
  const [tab, setTab] = useState('overview')
  const [side, setSide] = useState<'buy' | 'sell'>('buy')
  const [tf, setTf] = useState('8h')
  const [wsTab, setWsTab] = useState('balances')
  const [leverage, setLeverage] = useState(50)
  const [modal, setModal] = useState(false)
  const [amount, setAmount] = useState('5.500')

  return (
    <Backdrop>
      <div className="vx-shell">
        <TopNav
          name="voltrex"
          items={[
            { key: 'overview', label: 'Overview' },
            { key: 'trade', label: 'Trade' },
            { key: 'portfolio', label: 'Portfolio' },
            { key: 'activity', label: 'Activity' },
            { key: 'referrals', label: 'Referrals' },
            { key: 'settings', label: 'Settings' },
          ]}
          active={tab}
          onSelect={setTab}
          right={
            <>
              <Badge tone="outline">UI kit</Badge>
              <Button variant="square" size="sm">
                Login
              </Button>
            </>
          }
        />

        <main className="vx-main">
          {/* 01–04 ------------------------------------------------------- */}
          <div className="vx-grid" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))' }}>
            <Card pad>
              <SectionLabel n="01.">Colors</SectionLabel>
              <div className="vx-stat__sub" style={{ marginBottom: 8 }}>Brand</div>
              <div className="vx-row vx-wrap">
                {BRAND.map(([hex]) => (
                  <span key={hex} title={hex} style={{ width: 40, height: 40, borderRadius: 999, background: hex }} />
                ))}
              </div>
              <div className="vx-stat__sub" style={{ margin: '14px 0 8px' }}>Neutral</div>
              <div className="vx-row vx-wrap">
                {NEUTRAL.map(([hex, n]) => (
                  <span
                    key={n}
                    title={`${n} ${hex}`}
                    style={{ width: 34, height: 34, borderRadius: 999, background: hex, boxShadow: 'inset 0 0 0 1px rgba(16,24,40,.08)' }}
                  />
                ))}
              </div>
            </Card>

            <Card pad>
              <SectionLabel n="02.">Typography</SectionLabel>
              <div className="vx-row" style={{ alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
                <span style={{ font: 'var(--t-display)' }}>Aa</span>
                <span style={{ font: 'var(--t-h2)' }}>General Sans</span>
              </div>
              <KeyValue rows={TYPE.map(([n, s, w]) => [n, `${s} · ${w}`])} />
            </Card>

            <Card pad>
              <SectionLabel n="03.">Buttons</SectionLabel>
              <div className="vx-col" style={{ gap: 10 }}>
                <Button variant="primary" block arrow>Primary Button</Button>
                <Button variant="secondary" block arrow>Secondary Button</Button>
                <Button variant="tertiary" block arrow>Tertiary Button</Button>
                <div className="vx-row">
                  <IconButton label="Add"><Plus size={16} /></IconButton>
                  <IconButton label="Schedule"><Calendar size={16} /></IconButton>
                  <IconButton label="Swap"><ArrowLeftRight size={16} /></IconButton>
                  <IconButton label="More"><MoreHorizontal size={16} /></IconButton>
                </div>
              </div>
            </Card>

            <Card pad>
              <SectionLabel n="04.">Form Elements</SectionLabel>
              <div className="vx-col" style={{ gap: 12 }}>
                <Field label="Input"><Input placeholder="Enter value" trailing={<CircleHelp size={14} />} /></Field>
                <Field label="Dropdown">
                  <Select defaultValue="usdc">
                    <option value="usdc">Select currency</option>
                    <option value="usdt">USDT</option>
                  </Select>
                </Field>
                <Field label="Search"><SearchInput /></Field>
                <Field label="Error" error="This field is required">
                  <Input defaultValue="" placeholder="Enter value" invalid />
                </Field>
              </div>
            </Card>
          </div>

          {/* 05 ----------------------------------------------------------- */}
          <div>
            <SectionLabel n="05.">Cards / Stats</SectionLabel>
            <div className="vx-grid vx-grid--stats">
              {MARKETS.map((m, i) => (
                <StatCard key={m.pair} {...m} series={wave(22, i)} />
              ))}
            </div>
          </div>

          {/* 06 Market strip (kuru) --------------------------------------- */}
          <div>
            <SectionLabel n="06.">Market strip — kuru.io/trade</SectionLabel>
            <MarketStrip
              pair="BTC/USDT"
              pairIcon={<TokenDot symbol="B" color="#f7931a" />}
              onPickPair={() => {}}
              cells={[
                { k: 'Price', v: '97,417.05' },
                { k: '24h change', v: '+8.74%', tone: 'up' },
                { k: '24h volume', v: '$24.21B' },
                { k: 'Market cap', v: '$1.93T' },
                { k: 'Funding', v: '0.0041%' },
              ]}
              right={
                <>
                  <Segmented value={tf} onChange={setTf} options={['5m', '1h', '8h', '1D', '1W'].map((v) => ({ value: v, label: v }))} aria-label="Timeframe" />
                  <IconButton label="Watchlist"><Star size={15} /></IconButton>
                </>
              }
            />
          </div>

          {/* 07 Slider ---------------------------------------------------- */}
          <div>
            <SectionLabel n="07.">Slider — bencho.dev/bench</SectionLabel>
            <div className="vx-grid" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
              <Panel
                title="Wake"
                icon={<Activity size={15} />}
                footer="Thumbless bars. Sweep fast and the bars you pass spring up in a wake. The kit's only continuous control — everything else is a quick-pick pill."
              >
                <WakeSlider
                  label="Leverage"
                  value={leverage}
                  onChange={setLeverage}
                  min={0}
                  max={100}
                  step={1}
                  format={(v) => `${v}x`}
                  scale={['0', '25', '50', '75', '100']}
                  aside={<Badge tone="green">Low Risk</Badge>}
                />
              </Panel>

              <Panel
                title="Quick picks"
                icon={<Wallet size={15} />}
                footer="What replaced the other sliders: a big value and a row of presets."
              >
                <div className="tk-card__top">
                  <span className="tk-card__k">Amount</span>
                  <span className="tk-card__unit">USDT</span>
                </div>
                <div className="tk-card__v">{amount}</div>
                <QuickPills
                  options={['1.00', '2.00', '5.00', '10.00', '15.00']}
                  value={amount}
                  onPick={setAmount as never}
                />
              </Panel>
            </div>
          </div>

          {/* 08 Trade panel ------------------------------------------------ */}
          <div className="vx-grid" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
            <Panel title="08. Trade panel" icon={<ArrowLeftRight size={15} />}>
              <div className="vx-col">
                <Segmented
                  block
                  value={side}
                  onChange={setSide}
                  aria-label="Side"
                  options={[
                    { value: 'buy', label: 'BUY', tone: 'up' },
                    { value: 'sell', label: 'SELL', tone: 'down' },
                  ]}
                />
                <Card sunken pad>
                  <Field label="Amount" aside={<span className="vx-stat__sub">USDT</span>}>
                    <Input inputSize="lg" mono value={amount} onChange={(e) => setAmount(e.target.value)} />
                  </Field>
                  <div style={{ height: 10 }} />
                  <QuickPills options={['1.00', '2.00', '5.00', '10.00', '15.00']} value={amount} onPick={setAmount as never} />
                </Card>
                <Button variant="primary" block onClick={() => setModal(true)}>
                  Place Buy
                </Button>
                <KeyValue
                  rows={[
                    ['Execution price', '253,642.8'],
                    ['Spread', '0%'],
                    ['Slippage', '—'],
                    ['Notional value', '0.3 USDT'],
                    ['Borrow fee', '0 USDT (0.023%)'],
                    ['Daily limit', '10,000 USD'],
                  ]}
                />
              </div>
            </Panel>

            {/* 09 Ladder (kuru) ------------------------------------------- */}
            <Panel title="09. Depth ladder" icon={<BarChart3 size={15} />} bodyless>
              <Ladder
                template="1fr 1fr 1fr"
                columns={['Price', 'Size', 'Total']}
                mid={{ k: 'Mid', v: '97,417.05', after: 4 }}
                rows={[
                  ...[97421, 97420, 97419, 97418].map((p, i) => ({
                    key: `a${p}`,
                    side: 'down' as const,
                    depth: 0.9 - i * 0.18,
                    cells: [<span key="p" className="vx-down">{p.toLocaleString()}</span>, (1.2 + i).toFixed(3), (9.4 - i).toFixed(2)],
                  })),
                  ...[97416, 97415, 97414, 97413].map((p, i) => ({
                    key: `b${p}`,
                    side: 'up' as const,
                    depth: 0.25 + i * 0.2,
                    cells: [<span key="p" className="vx-up">{p.toLocaleString()}</span>, (0.8 + i).toFixed(3), (6.1 + i).toFixed(2)],
                  })),
                ]}
              />
            </Panel>

            {/* 10 Badges / tooltip / progress ------------------------------ */}
            <Panel title="10. Badges, tooltip, loaders" icon={<Star size={15} />}>
              <div className="vx-col">
                <div className="vx-row vx-wrap">
                  <Badge tone="teal">New</Badge>
                  <Badge tone="amber">Hot</Badge>
                  <Badge tone="green">Low Risk</Badge>
                  <Badge tone="red">High Risk</Badge>
                  <Badge tone="outline" icon={<CheckCircle2 size={12} color="var(--up)" />}>Verified</Badge>
                  <Badge tone="outline" icon={<Star size={12} color="var(--brand-violet)" />}>Popular</Badge>
                  <Delta value={8.74} />
                  <Delta value={-7.12} />
                </div>
                <Tooltip title="Leverage" text="Increasing leverage increases both potential profit and risk.">
                  <Button variant="tertiary" size="sm" icon={<CircleHelp size={14} />}>Hover me</Button>
                </Tooltip>
                <Progress value={62} label="Collateral used" />
                <div className="vx-row">
                  <Spinner />
                  <Skeleton width={120} />
                  <Skeleton width={60} />
                </div>
                <Tiles
                  items={[
                    { k: 'Total balance', v: '24,542.21' },
                    { k: '24h PnL', v: '+1,452.23', tone: 'up' },
                    { k: 'Total equity', v: '26,142.21' },
                    { k: 'Available', v: '5,642.21' },
                  ]}
                />
              </div>
            </Panel>
          </div>

          {/* 11 Alerts / modal / activity --------------------------------- */}
          <div className="vx-grid" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
            <Panel title="11. Alerts" icon={<Bell size={15} />}>
              <div className="vx-col" style={{ gap: 10 }}>
                <Alert tone="success" title="Success!" onDismiss={() => {}}>Your order has been placed successfully.</Alert>
                <Alert tone="warning" title="Warning!" onDismiss={() => {}}>Market is highly volatile. Trade carefully.</Alert>
                <Alert tone="error" title="Error!" onDismiss={() => {}}>Something went wrong. Try again later.</Alert>
                <Alert tone="info" title="Info" onDismiss={() => {}}>Maintenance in progress from 02:00 AM.</Alert>
              </div>
            </Panel>

            <Panel title="12. Activity" icon={<Activity size={15} />} bodyless>
              <ActivityList
                items={[
                  { icon: <Wallet size={15} />, title: 'Deposit', meta: 'Dec 11, 2024 · 10:34 AM', right: <Badge tone="green">Completed</Badge> },
                  { icon: <ArrowLeftRight size={15} />, title: 'Trade', meta: 'Dec 11, 2024 · 09:41 AM', right: <Badge tone="green">Completed</Badge> },
                  { icon: <TrendingUp size={15} />, title: 'Withdrawal', meta: 'Dec 10, 2024 · 08:15 PM', right: <Badge tone="amber">Pending</Badge> },
                  { icon: <Gift size={15} />, title: 'Referral Bonus', meta: 'Dec 10, 2024 · 05:22 PM', right: <Badge tone="green">Completed</Badge> },
                ]}
              />
            </Panel>

            <Panel title="13. Trending" icon={<Flame size={15} />} bodyless>
              <Rail
                rows={MARKETS.map((m) => ({
                  key: m.pair,
                  icon: <TokenDot symbol={m.pair} color={m.color} />,
                  name: m.pair,
                  sub: 'perp',
                  value: m.value,
                  change: m.change,
                }))}
              />
            </Panel>
          </div>

          {/* 14 Workspace tabs + table ------------------------------------ */}
          <Card>
            <Tabs
              aria-label="Workspace"
              value={wsTab}
              onChange={setWsTab}
              tabs={[
                { value: 'balances', label: 'Balances', count: 5 },
                { value: 'open', label: 'Open Orders', count: 0 },
                { value: 'history', label: 'Order History' },
                { value: 'trades', label: 'Trade History' },
              ]}
              right={<div style={{ paddingRight: 16 }}><SearchInput style={{ width: 180 }} /></div>}
            />
            {wsTab === 'balances' ? (
              <Table
                rows={MARKETS}
                columns={[
                  { key: 'pair', header: 'Pair', render: (r) => (
                    <span className="vx-row"><TokenDot symbol={r.pair} color={r.color} /> {r.pair}</span>
                  ) },
                  { key: 'price', header: 'Price', numeric: true, render: (r) => r.value },
                  { key: 'chg', header: '24h Change', numeric: true, render: (r) => <Delta value={r.change} /> },
                  { key: 'act', header: '', numeric: true, render: () => <Button size="sm" variant="primary">Trade</Button> },
                ]}
              />
            ) : (
              <EmptyState
                icon={<Inbox size={18} />}
                title="Nothing here yet"
                description="Your open orders and fills show up here once you place a trade."
                action={<Button size="sm" variant="secondary">Place an order</Button>}
              />
            )}
          </Card>

          {/* 15 Radius / shadows ------------------------------------------ */}
          <div className="vx-grid" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
            <Card pad>
              <SectionLabel n="15.">Border radius</SectionLabel>
              <div className="vx-row vx-wrap">
                {RADII.map((r) => (
                  <div key={r} style={{ textAlign: 'center' }}>
                    <div style={{ width: 46, height: 46, borderRadius: r, border: '1px solid var(--line-strong)' }} />
                    <div className="vx-stat__sub">{r}px</div>
                  </div>
                ))}
              </div>
            </Card>
            <Card pad>
              <SectionLabel n="16.">Shadows</SectionLabel>
              <div className="vx-row vx-wrap" style={{ gap: 18 }}>
                {SHADOWS.map(([n, v]) => (
                  <div key={n} style={{ textAlign: 'center' }}>
                    <div style={{ width: 46, height: 46, borderRadius: 12, background: '#fff', boxShadow: v }} />
                    <div className="vx-stat__sub" style={{ marginTop: 6 }}>{n}</div>
                  </div>
                ))}
              </div>
            </Card>
            <Card pad>
              <SectionLabel n="17.">Sparklines</SectionLabel>
              <Sparkline data={wave(26, 1)} color="var(--up)" height={52} />
              <Sparkline data={wave(26, 4)} color="var(--brand-amber)" height={52} />
              <Sparkline data={wave(26, 7)} color="var(--brand-violet)" height={52} />
            </Card>
          </div>
        </main>
      </div>

      <Modal
        open={modal}
        title="Confirm Order"
        onClose={() => setModal(false)}
        footer={
          <>
            <Button variant="primary" onClick={() => setModal(false)}>Confirm</Button>
            <Button variant="secondary" onClick={() => setModal(false)}>Cancel</Button>
          </>
        }
      >
        <Card sunken pad style={{ marginBottom: 12 }}>
          <div className="vx-row"><TokenDot symbol="B" color="#f7931a" /> <b>BTC/USDT</b></div>
          <div className="vx-up" style={{ font: '500 13px/18px var(--mono)', marginTop: 4 }}>Buy 0.025 BTC</div>
        </Card>
        <KeyValue
          rows={[
            ['Price', '97,417.05 USDT'],
            ['Amount', '0.025 BTC'],
            ['Total', '2,435.43 USDT'],
          ]}
        />
      </Modal>
    </Backdrop>
  )
}

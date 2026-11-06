/* ============================================================================
   Voltrex UI kit — components.
   Section numbers follow the reference board: 03 Buttons, 04 Form elements,
   05 Cards/Stats, 07 Badges, 10 Table, 11 Activity, 12 Alerts, 13 Modal,
   14 Tooltip, 15 Progress & loaders.
   ========================================================================= */

import { useEffect, useId, useRef, type ReactNode } from 'react'
import { AlertTriangle, ArrowRight, CheckCircle2, ChevronDown, Info, Loader2, Search, X, XCircle } from 'lucide-react'

const cx = (...parts: (string | false | null | undefined)[]) => parts.filter(Boolean).join(' ')

/* --- 03. Buttons ---------------------------------------------------------- */

export type ButtonVariant = 'primary' | 'secondary' | 'tertiary' | 'ghost' | 'danger' | 'square'

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: 'sm' | 'md' | 'lg'
  block?: boolean
  /** Trailing arrow, as on the reference board's primary/secondary buttons. */
  arrow?: boolean
  icon?: ReactNode
  loading?: boolean
}

export function Button({
  variant = 'secondary',
  size = 'md',
  block,
  arrow,
  icon,
  loading,
  children,
  className,
  disabled,
  ...rest
}: ButtonProps) {
  return (
    <button
      type="button"
      className={cx(
        'vx-btn',
        `vx-btn--${variant}`,
        size !== 'md' && `vx-btn--${size}`,
        block && 'vx-btn--block',
        className,
      )}
      disabled={disabled || loading}
      {...rest}
    >
      {loading ? <Loader2 size={15} className="vx-spinner" /> : icon}
      {children}
      {arrow && <ArrowRight size={15} className="vx-btn__arrow" />}
    </button>
  )
}

export interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Required — an icon with no text needs a name. */
  label: string
  bare?: boolean
  round?: boolean
}

export function IconButton({ label, bare, round, children, className, ...rest }: IconButtonProps) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      className={cx('vx-iconbtn', bare && 'vx-iconbtn--bare', round && 'vx-iconbtn--round', className)}
      {...rest}
    >
      {children}
    </button>
  )
}

/* --- 04. Form elements ---------------------------------------------------- */

export interface FieldProps {
  label?: ReactNode
  aside?: ReactNode
  hint?: ReactNode
  error?: ReactNode
  htmlFor?: string
  children: ReactNode
}

export function Field({ label, aside, hint, error, htmlFor, children }: FieldProps) {
  return (
    <div className="vx-field">
      {(label || aside) && (
        <label className="vx-field__label" htmlFor={htmlFor}>
          <span>{label}</span>
          {aside}
        </label>
      )}
      {children}
      {hint && !error && <span className="vx-field__hint">{hint}</span>}
      {error && (
        <span className="vx-field__error">
          <AlertTriangle size={12} /> {error}
        </span>
      )}
    </div>
  )
}

export interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  leading?: ReactNode
  trailing?: ReactNode
  invalid?: boolean
  mono?: boolean
  inputSize?: 'md' | 'lg'
}

export function Input({ leading, trailing, invalid, mono, inputSize = 'md', className, ...rest }: InputProps) {
  return (
    <div
      className={cx(
        'vx-input',
        invalid && 'vx-input--error',
        mono && 'vx-input--mono',
        inputSize === 'lg' && 'vx-input--lg',
        className,
      )}
    >
      {leading && <span className="vx-input__adorn">{leading}</span>}
      <input aria-invalid={invalid || undefined} {...rest} />
      {trailing && <span className="vx-input__adorn">{trailing}</span>}
    </div>
  )
}

export function SearchInput(props: InputProps) {
  return <Input leading={<Search size={15} />} placeholder="Search..." type="search" {...props} />
}

export interface SelectProps extends React.SelectHTMLAttributes<HTMLSelectElement> {
  invalid?: boolean
}

export function Select({ invalid, className, children, ...rest }: SelectProps) {
  return (
    <div className={cx('vx-input vx-select', invalid && 'vx-input--error', className)}>
      <select {...rest}>{children}</select>
      <span className="vx-input__adorn">
        <ChevronDown size={15} />
      </span>
    </div>
  )
}

/* --- Segmented control ---------------------------------------------------- */

export interface SegmentedOption<T> {
  value: T
  label: ReactNode
  /** Tints the selected pill green or red — used for BUY / SELL. */
  tone?: 'up' | 'down'
}

export interface SegmentedProps<T> {
  options: SegmentedOption<T>[]
  value: T
  onChange: (v: T) => void
  block?: boolean
  /** White selected pill instead of the black one. */
  light?: boolean
  'aria-label'?: string
}

export function Segmented<T extends string | number>({
  options,
  value,
  onChange,
  block,
  light,
  'aria-label': ariaLabel,
}: SegmentedProps<T>) {
  return (
    <div
      className={cx('vx-seg', block && 'vx-seg--block', light && 'vx-seg--light')}
      role="tablist"
      aria-label={ariaLabel}
    >
      {options.map((o) => (
        <button
          key={String(o.value)}
          type="button"
          role="tab"
          aria-selected={o.value === value}
          className={cx('vx-seg__btn', o.tone && `is-${o.tone}`)}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

export interface QuickPillsProps {
  options: (string | number)[]
  value?: string | number
  onPick: (v: never) => void
  format?: (v: string | number) => string
}

/** The 1.00 / 2.00 / 5.00 row under the amount field on the reference panel. */
export function QuickPills({ options, value, onPick, format }: QuickPillsProps) {
  return (
    <div className="vx-pills">
      {options.map((o) => (
        <button
          key={String(o)}
          type="button"
          className="vx-pill"
          aria-pressed={o === value}
          onClick={() => (onPick as (v: string | number) => void)(o)}
        >
          {format ? format(o) : o}
        </button>
      ))}
    </div>
  )
}

/* --- 07. Badges ----------------------------------------------------------- */

export type BadgeTone = 'teal' | 'amber' | 'green' | 'red' | 'violet' | 'slate' | 'neutral' | 'outline'

export function Badge({
  tone = 'neutral',
  icon,
  children,
}: {
  tone?: BadgeTone
  icon?: ReactNode
  children: ReactNode
}) {
  return (
    <span className={`vx-badge vx-badge--${tone}`}>
      {icon}
      {children}
    </span>
  )
}

/** Signed percentage pill — green up, red down, arrow included. */
export function Delta({ value, digits = 2 }: { value: number; digits?: number }) {
  const up = value >= 0
  return (
    <span className={`vx-delta vx-delta--${up ? 'up' : 'down'}`}>
      <span aria-hidden>{up ? '▲' : '▼'}</span>
      {Math.abs(value).toFixed(digits)}%
    </span>
  )
}

/* --- Card / Panel --------------------------------------------------------- */

export function Card({
  flat,
  sunken,
  pad,
  className,
  children,
  ...rest
}: { flat?: boolean; sunken?: boolean; pad?: boolean } & React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cx('vx-card', flat && 'vx-card--flat', sunken && 'vx-card--sunken', pad && 'vx-card--pad', className)}
      {...rest}
    >
      {children}
    </div>
  )
}

export function Panel({
  title,
  icon,
  actions,
  footer,
  bodyless,
  children,
  ...rest
}: {
  title?: ReactNode
  icon?: ReactNode
  actions?: ReactNode
  footer?: ReactNode
  /** Skip the body padding — for a chart or a table that should reach the edges. */
  bodyless?: boolean
  children?: ReactNode
} & React.HTMLAttributes<HTMLDivElement>) {
  return (
    <Card {...rest}>
      {(title || actions) && (
        <div className="vx-panel__head">
          <div className="vx-panel__title">
            {icon}
            {title}
          </div>
          {actions}
        </div>
      )}
      {bodyless ? children : <div className="vx-panel__body">{children}</div>}
      {footer && <div className="vx-panel__foot">{footer}</div>}
    </Card>
  )
}

export function SectionLabel({ n, children }: { n?: string; children: ReactNode }) {
  return (
    <div className="vx-sectionlabel">
      {n && <b>{n}</b>}
      {children}
    </div>
  )
}

/* --- 05. Cards / Stats ---------------------------------------------------- */

export function TokenDot({ symbol, color }: { symbol: string; color: string }) {
  return (
    <span className="vx-token" style={{ background: color }} aria-hidden>
      {symbol.slice(0, 1)}
    </span>
  )
}

export interface SparklineProps {
  data: number[]
  color?: string
  height?: number
  /** Draw a dot on the last point, as the reference stat cards do. */
  dot?: boolean
}

export function Sparkline({ data, color = 'var(--brand-teal)', height = 40, dot = true }: SparklineProps) {
  if (data.length < 2) return <svg className="vx-spark" height={height} />
  const lo = Math.min(...data)
  const hi = Math.max(...data)
  const span = hi - lo || 1
  const W = 100
  const pad = 3
  const px = (i: number) => 2 + (i / (data.length - 1)) * (W - 4)
  const py = (v: number) => pad + (1 - (v - lo) / span) * (height - pad * 2)

  // Smooth through the points with quadratics anchored at the midpoints.
  let d = `M ${px(0)} ${py(data[0])}`
  for (let i = 1; i < data.length; i++) {
    const mx = (px(i - 1) + px(i)) / 2
    const my = (py(data[i - 1]) + py(data[i])) / 2
    d += ` Q ${px(i - 1)} ${py(data[i - 1])} ${mx} ${my}`
  }
  d += ` L ${px(data.length - 1)} ${py(data[data.length - 1])}`

  return (
    <svg className="vx-spark" height={height} viewBox={`0 0 ${W} ${height}`} preserveAspectRatio="none" aria-hidden>
      <path d={d} fill="none" stroke={color} strokeWidth={1.6} strokeLinecap="round" vectorEffect="non-scaling-stroke" />
      {dot && (
        <circle
          cx={px(data.length - 1)}
          cy={py(data[data.length - 1])}
          r={2.6}
          fill="var(--surface)"
          stroke={color}
          strokeWidth={1.6}
          vectorEffect="non-scaling-stroke"
        />
      )}
    </svg>
  )
}

export interface StatCardProps {
  pair: string
  color: string
  value: string
  sub?: string
  /** Omit to hide the delta pill entirely. */
  change?: number
  series?: number[]
}

export function StatCard({ pair, color, value, sub, change, series }: StatCardProps) {
  const tint = (change ?? 0) >= 0 ? 'var(--up)' : 'var(--down)'
  return (
    <Card className="vx-stat">
      <div className="vx-stat__top">
        <TokenDot symbol={pair} color={color} />
        <span className="vx-stat__pair">{pair}</span>
      </div>
      <div className="vx-stat__value">{value}</div>
      <div className="vx-stat__row">
        {sub && <span className="vx-stat__sub">{sub}</span>}
        {change != null && <Delta value={change} />}
      </div>
      {series && <Sparkline data={series} color={tint} />}
    </Card>
  )
}

/* --- Key / value --------------------------------------------------------- */

export function KeyValue({ rows }: { rows: [ReactNode, ReactNode][] }) {
  return (
    <div className="vx-kv">
      {rows.map(([k, v], i) => (
        <div className="vx-kv__row" key={i}>
          <span className="vx-kv__k">{k}</span>
          <span className="vx-kv__v">{v}</span>
        </div>
      ))}
    </div>
  )
}

export function Tiles({ items }: { items: { k: ReactNode; v: ReactNode; tone?: 'up' | 'down' }[] }) {
  return (
    <div className="vx-tiles">
      {items.map((t, i) => (
        <div className="vx-tile" key={i}>
          <div className="vx-tile__k">{t.k}</div>
          <div className={cx('vx-tile__v', t.tone === 'up' && 'vx-up', t.tone === 'down' && 'vx-down')}>{t.v}</div>
        </div>
      ))}
    </div>
  )
}

/* --- 10. Table ------------------------------------------------------------ */

export interface Column<R> {
  key: string
  header: ReactNode
  numeric?: boolean
  render: (row: R, i: number) => ReactNode
}

export function Table<R>({ columns, rows, empty }: { columns: Column<R>[]; rows: R[]; empty?: ReactNode }) {
  if (!rows.length) return <div className="vx-empty">{empty ?? 'Nothing here yet.'}</div>
  return (
    <div className="vx-table__scroll">
      <table className="vx-table">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={c.numeric ? 'num-col' : undefined}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i}>
              {columns.map((c) => (
                <td key={c.key} className={c.numeric ? 'num-col' : undefined}>
                  {c.render(r, i)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/* --- 11. Activity list ---------------------------------------------------- */

export interface ActivityItem {
  icon?: ReactNode
  title: ReactNode
  meta?: ReactNode
  right?: ReactNode
}

export function ActivityList({ items, empty }: { items: ActivityItem[]; empty?: ReactNode }) {
  if (!items.length) return <div className="vx-empty">{empty ?? 'No activity yet.'}</div>
  return (
    <div className="vx-activity">
      {items.map((it, i) => (
        <div className="vx-activity__row" key={i}>
          {it.icon && <span className="vx-activity__icon">{it.icon}</span>}
          <div className="vx-activity__main">
            <div className="vx-activity__title">{it.title}</div>
            {it.meta && <div className="vx-activity__meta">{it.meta}</div>}
          </div>
          {it.right}
        </div>
      ))}
    </div>
  )
}

/* --- 12. Alerts ----------------------------------------------------------- */

export type AlertTone = 'success' | 'warning' | 'error' | 'info' | 'neutral'

const ALERT_ICON: Record<AlertTone, ReactNode> = {
  success: <CheckCircle2 size={16} />,
  warning: <AlertTriangle size={16} />,
  error: <XCircle size={16} />,
  info: <Info size={16} />,
  neutral: <Info size={16} />,
}

export function Alert({
  tone = 'info',
  title,
  onDismiss,
  children,
}: {
  tone?: AlertTone
  title?: ReactNode
  onDismiss?: () => void
  children?: ReactNode
}) {
  return (
    <div className={`vx-alert vx-alert--${tone}`} role={tone === 'error' ? 'alert' : 'status'}>
      <span className="vx-alert__icon">{ALERT_ICON[tone]}</span>
      <div className="vx-alert__body">
        {title && <div className="vx-alert__title">{title}</div>}
        {children}
      </div>
      {onDismiss && (
        <IconButton label="Dismiss" bare onClick={onDismiss} style={{ width: 22, height: 22, color: 'inherit' }}>
          <X size={14} />
        </IconButton>
      )}
    </div>
  )
}

/* --- 13. Modal ------------------------------------------------------------ */

export function Modal({
  open,
  title,
  onClose,
  footer,
  children,
}: {
  open: boolean
  title?: ReactNode
  onClose: () => void
  footer?: ReactNode
  children?: ReactNode
}) {
  const titleId = useId()
  const box = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    box.current?.focus()
    return () => document.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null
  return (
    <div className="vx-modal__scrim" onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div
        ref={box}
        className="vx-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? titleId : undefined}
        tabIndex={-1}
      >
        {title && (
          <div className="vx-modal__head">
            <div className="vx-modal__title" id={titleId}>
              {title}
            </div>
            <IconButton label="Close" bare onClick={onClose}>
              <X size={16} />
            </IconButton>
          </div>
        )}
        <div className="vx-modal__body">{children}</div>
        {footer && <div className="vx-modal__foot">{footer}</div>}
      </div>
    </div>
  )
}

/* --- 14. Tooltip ---------------------------------------------------------- */

export function Tooltip({
  title,
  text,
  children,
}: {
  title?: ReactNode
  text: ReactNode
  children: ReactNode
}) {
  return (
    <span className="vx-tip" tabIndex={0}>
      {children}
      <span className="vx-tip__bubble" role="tooltip">
        {title && <span className="vx-tip__title">{title}</span>}
        <span className="vx-tip__text">{text}</span>
      </span>
    </span>
  )
}

/* --- 15. Progress & loaders ----------------------------------------------- */

export function Progress({ value, max = 100, label }: { value: number; max?: number; label?: string }) {
  const pct = Math.round((value / max) * 100)
  return (
    <div className="vx-progress">
      <div
        className="vx-progress__track"
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={max}
        aria-valuenow={value}
      >
        <div className="vx-progress__fill" style={{ width: `${pct}%` }} />
      </div>
      <span className="vx-progress__val">{pct}%</span>
    </div>
  )
}

export function Spinner({ size = 18 }: { size?: number }) {
  return <Loader2 size={size} className="vx-spinner" aria-label="Loading" />
}

export function Skeleton({ width = '100%', height = 14, radius }: { width?: number | string; height?: number; radius?: number }) {
  return <div className="vx-skeleton" style={{ width, height, borderRadius: radius }} aria-hidden />
}

export function Toast({ children }: { children: ReactNode }) {
  return (
    <div className="vx-toast" role="status">
      <CheckCircle2 size={15} />
      {children}
    </div>
  )
}

/* --- Shell ---------------------------------------------------------------- */

export function Backdrop({ children }: { children: ReactNode }) {
  return <div className="vx-backdrop">{children}</div>
}

export interface NavItem {
  key: string
  label: string
  icon?: ReactNode
}

/** onverre's asterisk mark, redrawn. Six strokes through a common centre. */
export function Asterisk({ size = 17 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden>
      <g stroke="currentColor" strokeWidth="3.1" strokeLinecap="round">
        <path d="M12 3.2v17.6M4.4 7.6l15.2 8.8M19.6 7.6L4.4 16.4" />
      </g>
    </svg>
  )
}

export function Wordmark({ name, onClick }: { name: string; onClick?: () => void }) {
  return (
    <button type="button" className="vx-wordmark" onClick={onClick} aria-label={`${name} home`}>
      <Asterisk />
      {name}
    </button>
  )
}

/**
 * Top nav in onverre's shape: wordmark, plain-text links, one square action on
 * the right. Below 880px the links collapse into a select so every view stays
 * reachable without a drawer.
 */
export function TopNav({
  name,
  items,
  active,
  onSelect,
  right,
}: {
  name: string
  items: NavItem[]
  active: string
  onSelect: (key: string) => void
  right?: ReactNode
}) {
  return (
    <nav className="vx-topnav" aria-label="Main navigation">
      <Wordmark name={name} onClick={() => onSelect(items[0]?.key)} />

      <div className="vx-topnav__links">
        {items.map((it) => (
          <button
            key={it.key}
            type="button"
            className="vx-topnav__link"
            aria-current={it.key === active ? 'page' : undefined}
            onClick={() => onSelect(it.key)}
          >
            {it.label}
          </button>
        ))}
      </div>

      <div className="vx-topnav__picker">
        <Select
          value={active}
          onChange={(e) => onSelect(e.target.value)}
          aria-label="Section"
        >
          {items.map((it) => (
            <option key={it.key} value={it.key}>
              {it.label}
            </option>
          ))}
        </Select>
      </div>

      {right && <div className="vx-topnav__right">{right}</div>}
    </nav>
  )
}

export function Hero({
  eyebrow,
  title,
  lede,
  actions,
}: {
  eyebrow?: ReactNode
  title: ReactNode
  lede?: ReactNode
  actions?: ReactNode
}) {
  return (
    <header className="vx-hero">
      {eyebrow && <span className="vx-hero__eyebrow">{eyebrow}</span>}
      <h1 className="vx-hero__title">{title}</h1>
      {lede && <p className="vx-hero__lede">{lede}</p>}
      {actions && <div className="vx-hero__actions">{actions}</div>}
    </header>
  )
}

export function Brand({ mark, name, sub }: { mark: ReactNode; name: string; sub?: string }) {
  return (
    <div className="vx-brand">
      <span className="vx-brand__mark">{mark}</span>
      <div>
        <div className="vx-brand__name">{name}</div>
        {sub && <div className="vx-stat__sub">{sub}</div>}
      </div>
    </div>
  )
}

/* ============================================================================
   Kuru-derived trading structures (kuru.io/trade), in the Voltrex language.
   ========================================================================= */

/* --- Market strip --------------------------------------------------------- */

export interface StripCell {
  k: ReactNode
  v: ReactNode
  tone?: 'up' | 'down'
}

export function MarketStrip({
  pair,
  pairIcon,
  onPickPair,
  cells,
  right,
}: {
  pair: string
  pairIcon?: ReactNode
  onPickPair?: () => void
  cells: StripCell[]
  right?: ReactNode
}) {
  return (
    <Card className="vx-strip" aria-label="Market strip">
      <button type="button" className="vx-strip__pair" onClick={onPickPair} aria-label="Choose market">
        {pairIcon}
        <span className="vx-strip__pairname">{pair}</span>
        {onPickPair && <ChevronDown size={15} className="vx-muted" />}
      </button>
      {cells.map((c, i) => (
        <div className="vx-strip__cell" key={i}>
          <span className="vx-strip__k">{c.k}</span>
          <span className={cx('vx-strip__v', c.tone === 'up' && 'vx-up', c.tone === 'down' && 'vx-down')}>{c.v}</span>
        </div>
      ))}
      {right && (
        <>
          <span className="vx-spacer" />
          <div className="vx-row">{right}</div>
        </>
      )}
    </Card>
  )
}

/* --- Workspace tabs ------------------------------------------------------- */

export interface TabDef<T> {
  value: T
  label: ReactNode
  count?: number
}

export function Tabs<T extends string>({
  tabs,
  value,
  onChange,
  right,
  'aria-label': ariaLabel,
}: {
  tabs: TabDef<T>[]
  value: T
  onChange: (v: T) => void
  right?: ReactNode
  'aria-label'?: string
}) {
  return (
    <div className="vx-tabs" role="tablist" aria-label={ariaLabel}>
      {tabs.map((t) => (
        <button
          key={t.value}
          type="button"
          role="tab"
          aria-selected={t.value === value}
          className="vx-tabs__btn"
          onClick={() => onChange(t.value)}
        >
          {t.label}
          {t.count != null && <span className="vx-tabs__count">{t.count}</span>}
        </button>
      ))}
      {right && (
        <>
          <span className="vx-spacer" />
          {right}
        </>
      )}
    </div>
  )
}

/* --- Depth ladder --------------------------------------------------------- */

export interface LadderRow {
  key: string
  /** 0..1 — how far the depth shading reaches across the row. */
  depth: number
  side: 'up' | 'down'
  cells: ReactNode[]
  active?: boolean
  onSelect?: () => void
}

export function Ladder({
  columns,
  template = '1fr 1fr 1fr',
  rows,
  mid,
  empty,
}: {
  columns: ReactNode[]
  /** grid-template-columns for both header and rows. */
  template?: string
  rows: LadderRow[]
  /** The band between the two halves — mid price, spot, whatever anchors it. */
  mid?: { k: ReactNode; v: ReactNode; right?: ReactNode; after?: number }
  empty?: ReactNode
}) {
  const body = (slice: LadderRow[]) =>
    slice.map((r) => (
      <button
        key={r.key}
        type="button"
        className="vx-ladder__row"
        style={{ gridTemplateColumns: template }}
        aria-current={r.active || undefined}
        onClick={r.onSelect}
      >
        <span className={`vx-ladder__depth is-${r.side}`} style={{ width: `${clampPct(r.depth)}%` }} />
        {r.cells.map((c, i) => (
          <span key={i} className={i === 0 ? undefined : 'num-r'}>
            {c}
          </span>
        ))}
      </button>
    ))

  if (!rows.length) return <div className="vx-empty">{empty ?? 'No levels.'}</div>
  const cut = mid?.after ?? rows.length

  return (
    <div className="vx-ladder">
      <div className="vx-ladder__head" style={{ gridTemplateColumns: template }}>
        {columns.map((c, i) => (
          <span key={i} className={i === 0 ? undefined : 'num-r'}>
            {c}
          </span>
        ))}
      </div>
      {body(rows.slice(0, cut))}
      {mid && (
        <div className="vx-ladder__mid">
          <span className="vx-ladder__midk">{mid.k}</span>
          <span>{mid.v}</span>
          {mid.right}
        </div>
      )}
      {cut < rows.length && body(rows.slice(cut))}
    </div>
  )
}

const clampPct = (v: number) => Math.max(0, Math.min(100, v * 100))

/* --- Trending / watchlist rail -------------------------------------------- */

export interface RailRow {
  key: string
  icon?: ReactNode
  name: ReactNode
  sub?: ReactNode
  value: ReactNode
  change?: number
  onSelect?: () => void
}

export function Rail({ rows }: { rows: RailRow[] }) {
  return (
    <div className="vx-rail">
      {rows.map((r) => (
        <button key={r.key} type="button" className="vx-rail__row" onClick={r.onSelect}>
          {r.icon}
          <span>
            <span className="vx-rail__name">{r.name}</span>
            {r.sub && <div className="vx-rail__sub">{r.sub}</div>}
          </span>
          <span style={{ textAlign: 'right' }}>
            <div className="vx-rail__sub" style={{ color: 'var(--ink)' }}>
              {r.value}
            </div>
            {r.change != null && <Delta value={r.change} />}
          </span>
        </button>
      ))}
    </div>
  )
}

/* --- Empty state ---------------------------------------------------------- */

export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon?: ReactNode
  title: ReactNode
  description?: ReactNode
  action?: ReactNode
}) {
  return (
    <div className="vx-emptystate">
      {icon && <span className="vx-emptystate__icon">{icon}</span>}
      <div className="vx-emptystate__title">{title}</div>
      {description && <div className="vx-emptystate__desc">{description}</div>}
      {action}
    </div>
  )
}

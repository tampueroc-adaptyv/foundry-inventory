#import "@preview/charged-ieee:0.1.4": ieee

#let paper(title: none, abstract: none, index-terms: (), body) = {
  show: ieee.with(title: block(width: 100%, title), abstract: abstract, index-terms: index-terms)

  // Keep the source's unnumbered equations and size wide expressions to a column.
  set math.equation(numbering: none)
  show math.equation.where(block: true): it => layout(size => {
    let width = measure(it).width
    if width > size.width {
      scale(x: size.width / width * 100%, reflow: true, it)
    } else {
      it
    }
  })

  // Compact, breakable tables with repeated headers in the two-column layout.
  set table(
    inset: (x: 4pt, y: 4pt),
    align: left + top,
    stroke: (x, y) => if y <= 1 { (top: 0.5pt) },
    fill: (x, y) => if y > 0 and calc.even(y) { luma(95%) },
  )
  show table: set text(size: 8pt)
  show table: set par(first-line-indent: 0pt, leading: 0.4em)
  show raw.where(block: false): set text(size: 8pt)

  body
}

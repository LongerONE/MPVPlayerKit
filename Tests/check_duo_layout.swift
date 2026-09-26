import CoreGraphics

@main
struct DuoLayoutCheck {
    static func main() {
        let ordinary = CGRect(x: 0, y: 0, width: 932, height: 430)
        assert(MPVDuoLayout.regions(in: ordinary, divisions: []) == nil)
        let safe = CGRect(x: 24, y: 32, width: 760, height: 680)
        let horizontal = CGRect(x: 0, y: 350, width: 820, height: 24)
        let tabletop = MPVDuoLayout.regions(in: safe, divisions: [horizontal])!
        assert(tabletop.media == CGRect(x: 24, y: 32, width: 760, height: 318))
        assert(tabletop.controls == CGRect(x: 24, y: 374, width: 760, height: 338))
        let vertical = CGRect(x: 394, y: 0, width: 20, height: 800)
        let book = MPVDuoLayout.regions(in: safe, divisions: [vertical])!
        assert(book.media.maxX == 394 && book.controls.minX == 414)
        assert(!book.media.intersects(book.controls))
        assert(MPVDuoLayout.regions(in: ordinary, divisions: [CGRect(x: 1000, y: 0, width: 10, height: 900)]) == nil)
        assert(MPVDuoLayout.regions(in: ordinary, divisions: [ordinary]) == nil)
        print("PASS: ordinary landscape, tabletop, book, inactive/outside and invalid regions")
    }
}

import Foundation
import FractalKit

/// A place worth visiting: curated, or saved by the user.
struct Location: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let formula: Formula
    let re: String
    let im: String
    /// log10 of the magnification.
    let zoom: Double
    var rotation: Double = 0
    var palette: Int?
    var maxIter: Int?

    var viewport: Viewport? {
        let prec = max(64, Int(zoom * 3.33) + 96)
        guard let c = PlanePoint(re: re, im: im, precision: prec) else { return nil }
        return Viewport(center: c, log2Radius: 1 - zoom / log10(2.0), rotation: rotation * .pi / 180)
    }

    var depthText: String {
        zoom < 3 ? String(format: "%.0f×", pow(10, zoom)) : ScaleFact.power(Int(zoom.rounded()))
    }

    static func == (a: Location, b: Location) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Captures a view with enough digits to restore it exactly.
    init(id: String, name: String, formula: Formula, view: Viewport, palette: Int?, maxIter: Int?) {
        let digits = max(20, Int(view.zoomLog10) + 20)
        self.id = id
        self.name = name
        self.formula = formula
        re = view.center.re.string(digits: digits)
        im = view.center.im.string(digits: digits)
        zoom = view.zoomLog10
        rotation = view.rotation * 180 / .pi
        self.palette = palette
        self.maxIter = maxIter
    }

    init(id: String, name: String, formula: Formula, re: String, im: String, zoom: Double, rotation: Double = 0,
         palette: Int? = nil, maxIter: Int? = nil) {
        self.id = id
        self.name = name
        self.formula = formula
        self.re = re
        self.im = im
        self.zoom = zoom
        self.rotation = rotation
        self.palette = palette
        self.maxIter = maxIter
    }
}

extension Location {
    static let mandel = Formula()

    static let all: [Location] = [
        Location(id: "seahorse", name: "Seahorse Valley", formula: mandel,
                 re: "-0.74364",
                 im: "0.13183",
                 zoom: 4.6, palette: 0),
        Location(id: "elephant", name: "Elephant Valley", formula: mandel,
                 re: "0.2826",
                 im: "0.0101",
                 zoom: 2.8, palette: 5),
        Location(id: "triple", name: "Triple Spiral", formula: mandel,
                 re: "-0.0879",
                 im: "0.6557",
                 zoom: 3.3, palette: 8),
        Location(id: "mini3", name: "Mini Mandelbrot", formula: mandel,
                 re: "-1.7548776662466927",
                 im: "0",
                 zoom: 1.6, palette: 1),
        Location(id: "galaxy", name: "Spiral Galaxy", formula: mandel,
                 re: "-0.743643887037158704752191506114774",
                 im: "0.131825904205311970493132056385139",
                 zoom: 14, palette: 0),
        Location(id: "crown", name: "Seahorse Crown", formula: mandel,
                 re: "-0.743643887037158704752191506114774",
                 im: "0.131825904205311970493132056385139",
                 zoom: 30, palette: 0),
        Location(id: "twin", name: "Hidden Twin", formula: mandel,
                 re: "-0.74364388703715870475219150611477977821525621",
                 im: "0.13182590420531197049313205638514067897295228",
                 zoom: 31.87, palette: 0),
        Location(id: "garden", name: "Julia Garden", formula: mandel,
                 re: "2.901628397571327692619280653135281339347624330340722072258848182684172235759691753549278110635766737332133e-01",
                 im: "4.853690157695084040829521908586030568441338964515024500165102864639670418641834217257328507983264248457722e-01",
                 zoom: 84, palette: 1),
        Location(id: "ancient", name: "Ancient Mandelbrot", formula: mandel,
                 re: "2.901628397571327692619280653135281339347624330340722072258848182684172235759691753549278110635766737332133e-01",
                 im: "4.853690157695084040829521908586030568441338964515024500165102864639670418641834217257328507983264248457722e-01",
                 zoom: 94.6, palette: 1),
        Location(id: "abyss", name: "Abyssal Spiral", formula: mandel,
                 re: "2.90162839757132769261928065313528133926800060416256807223259011512431762096165431373667412040114758025249959606292256318914232972669925653248727774478919054783147135754426693432947558517707979781195828159497477312624256744619321324430807569450519939490212477109916369317638592961445541188108564294012003496121832e-01",
                 im: "4.85369015769508404082952190858603056850524359676689617246528500903960753735526597073988101113534001742647096268742997359766432825275606441733517703418760094116081258431977858841458824905168975082386634102161964953912030494080547064138658609418449139583387751242477472880102180690081213198849940278727431771411254e-01",
                 zoom: 298, palette: 8),
        Location(id: "edge", name: "Edge of Numbers", formula: mandel,
                 re: "2.901628397571327692619280653135281339347624330339884888560936518793907869166240211395833240588404209841359399493688718780604544584274275918437103513088927202972114131373024599803117356337771103811236490151606633409106901571767981370271986488124826298260106421534970080032983005757519084145132782276538516161051573119772644199786108190387388047563475808365585633468825525427958599726432219742736856798998645512493020291866551460432731880905565316544218975195158946026634418764756943047262975428088903651593646539439422531469968208243207306819373328402010209205627212852924442477748041937142400829439140166564065079423055025185144668112538672426825314619595487834708774036847052385464251095409057739148921120792171485213930826815589509451526000254496478093031326323427484282520314023300735630590881302653809897075272431285979071111327343549390010725777904520274949773975875461763209420228215899160918569250582055694175624610048035484320879492177492925621893469632752452072463859371997508218150607088862194375450801e-01",
                 im: "4.853690157695084040829521908586030568441338964515167071133535091844077497951198554127317620342371442508677994179795063495137244525281506163884716845416362192257861934773859661703996776469335947164625060325208021869650633212513648721371509439018301199175531269857340950953897855465391679834825418883921275638199797417871845465295858725936696099000174059187381158926145133505839696312381365462912995007076441417021523690951168340867993903915247874835465036375500903792596514266476852185995198060970256885067931694195287547191297693969987167752270593093998938266990266816192053874115063240043204638425508599516926101974290154849081849432469512729849945966447900664108187117104610405832761557248281076369789810161789371554087008674529504043662208366663219364073430050936304824054941994878559210888610076095111161107225004367561181052585620265263777859346429572827802328603179639228748089627221276985276980728688257662776636378709316362578803702831534766965415812100072612526011752902944042413515729872476089920922050e-01",
                 zoom: 998, palette: 8),
        Location(id: "armada", name: "The Armada", formula: Formula(family: .burningShip),
                 re: "-1.7619",
                 im: "-0.0283",
                 zoom: 1.6, palette: 0),
        Location(id: "rabbit", name: "Douady Rabbit", formula: Formula(julia: true, juliaRe: -0.123, juliaIm: 0.745),
                 re: "0",
                 im: "0",
                 zoom: 0.12, palette: 3),
        Location(id: "dragon", name: "Julia Dragon", formula: Formula(julia: true, juliaRe: -0.8, juliaIm: 0.156),
                 re: "0",
                 im: "0",
                 zoom: 0.12, palette: 1),
        Location(id: "dragonheart", name: "Dragon's Heart", formula: Formula(julia: true, juliaRe: -0.8, juliaIm: 0.156),
                 re: "9.2094645020940582626851522862967655388992553348364871932794133554956931177360834618592219006e-01",
                 im: "2.2268796738723574853706145023096819250345958434063934303890347912800356388352542342045748419e-02",
                 zoom: 60, palette: 1),
        Location(id: "spirals", name: "Julia Spirals", formula: Formula(julia: true, juliaRe: -0.7269, juliaIm: 0.1889),
                 re: "0",
                 im: "0",
                 zoom: 0.1, palette: 8),
        Location(id: "cubic", name: "Multibrot z³", formula: Formula(family: .mandelbrot, power: 3),
                 re: "0",
                 im: "0",
                 zoom: 0.05, palette: 9),
        Location(id: "tricorn", name: "Tricorn", formula: Formula(family: .tricorn),
                 re: "0",
                 im: "0",
                 zoom: 0.05, palette: 4),
        Location(id: "celtic", name: "Celtic", formula: Formula(family: .celtic),
                 re: "0",
                 im: "0",
                 zoom: 0.0, palette: 2),
    ]
}

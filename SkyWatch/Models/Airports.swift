import Foundation

/// An arrival airport the user can pick for flight tracking.
struct Airport: Identifiable, Hashable, Sendable {
    let iata: String
    let name: String
    let city: String
    let coordinate: Coordinate

    var id: String { iata }

    /// Looks up an airport by IATA code, case-insensitively. Used to
    /// auto-detect the arrival airport from FlightAware's destination code.
    static func find(iata code: String) -> Airport? {
        let key = code.uppercased()
        return common.first { $0.iata == key }
    }

    /// A short pickup-oriented list of major airports, ordered roughly by
    /// relevance to the app's likely users. Coordinates are runway-reference
    /// points; great-circle error of a few NM is irrelevant at ETA scale.
    static let common: [Airport] = [
        // Malaysia
        Airport(iata: "KUL", name: "Kuala Lumpur Intl", city: "Kuala Lumpur", coordinate: .init(latitude: 2.7456, longitude: 101.7099)),
        Airport(iata: "SZB", name: "Sultan Abdul Aziz Shah", city: "Subang", coordinate: .init(latitude: 3.1306, longitude: 101.5493)),
        Airport(iata: "PEN", name: "Penang Intl", city: "George Town", coordinate: .init(latitude: 5.2971, longitude: 100.2767)),
        Airport(iata: "JHB", name: "Senai Intl", city: "Johor Bahru", coordinate: .init(latitude: 1.6413, longitude: 103.6696)),
        Airport(iata: "BKI", name: "Kota Kinabalu Intl", city: "Kota Kinabalu", coordinate: .init(latitude: 5.9372, longitude: 116.0510)),
        Airport(iata: "KCH", name: "Kuching Intl", city: "Kuching", coordinate: .init(latitude: 1.4847, longitude: 110.3469)),
        Airport(iata: "LGK", name: "Langkawi Intl", city: "Langkawi", coordinate: .init(latitude: 6.3297, longitude: 99.7287)),
        Airport(iata: "AOR", name: "Sultan Abdul Halim", city: "Alor Setar", coordinate: .init(latitude: 6.1897, longitude: 100.3981)),
        Airport(iata: "MYY", name: "Miri", city: "Miri", coordinate: .init(latitude: 4.3220, longitude: 113.9873)),
        Airport(iata: "SBW", name: "Sibu", city: "Sibu", coordinate: .init(latitude: 2.2616, longitude: 111.9856)),
        Airport(iata: "TWU", name: "Tawau", city: "Tawau", coordinate: .init(latitude: 4.3134, longitude: 118.1220)),
        // Singapore
        Airport(iata: "SIN", name: "Changi", city: "Singapore", coordinate: .init(latitude: 1.3644, longitude: 103.9915)),
        // Indonesia
        Airport(iata: "CGK", name: "Soekarno-Hatta", city: "Jakarta", coordinate: .init(latitude: -6.1256, longitude: 106.6559)),
        Airport(iata: "DPS", name: "Ngurah Rai", city: "Bali", coordinate: .init(latitude: -8.7482, longitude: 115.1670)),
        Airport(iata: "SUB", name: "Juanda", city: "Surabaya", coordinate: .init(latitude: -7.3798, longitude: 112.7869)),
        Airport(iata: "BDO", name: "Husein Sastranegara", city: "Bandung", coordinate: .init(latitude: -6.9006, longitude: 107.5763)),
        Airport(iata: "KNO", name: "Kualanamu", city: "Medan", coordinate: .init(latitude: 3.6424, longitude: 98.8852)),
        Airport(iata: "UPG", name: "Sultan Hasanuddin", city: "Makassar", coordinate: .init(latitude: -5.0616, longitude: 119.5541)),
        Airport(iata: "BPN", name: "Sultan Aji Muhammad Sulaiman", city: "Balikpapan", coordinate: .init(latitude: -1.2683, longitude: 116.8945)),
        // Thailand
        Airport(iata: "BKK", name: "Suvarnabhumi", city: "Bangkok", coordinate: .init(latitude: 13.6900, longitude: 100.7501)),
        Airport(iata: "DMK", name: "Don Mueang", city: "Bangkok", coordinate: .init(latitude: 13.9126, longitude: 100.6067)),
        Airport(iata: "CNX", name: "Chiang Mai Intl", city: "Chiang Mai", coordinate: .init(latitude: 18.7668, longitude: 98.9626)),
        Airport(iata: "HKT", name: "Phuket Intl", city: "Phuket", coordinate: .init(latitude: 8.1132, longitude: 98.3169)),
        // Vietnam
        Airport(iata: "SGN", name: "Tan Son Nhat", city: "Ho Chi Minh City", coordinate: .init(latitude: 10.8188, longitude: 106.6520)),
        Airport(iata: "HAN", name: "Noi Bai", city: "Hanoi", coordinate: .init(latitude: 21.2212, longitude: 105.8072)),
        Airport(iata: "DAD", name: "Da Nang", city: "Da Nang", coordinate: .init(latitude: 16.0439, longitude: 108.1994)),
        // Philippines
        Airport(iata: "MNL", name: "Ninoy Aquino", city: "Manila", coordinate: .init(latitude: 14.5086, longitude: 121.0198)),
        Airport(iata: "CEB", name: "Mactan-Cebu", city: "Cebu", coordinate: .init(latitude: 10.3075, longitude: 123.9794)),
        // Hong Kong / Taiwan / China
        Airport(iata: "HKG", name: "Hong Kong Intl", city: "Hong Kong", coordinate: .init(latitude: 22.3080, longitude: 113.9185)),
        Airport(iata: "TPE", name: "Taiwan Taoyuan", city: "Taipei", coordinate: .init(latitude: 25.0777, longitude: 121.2328)),
        Airport(iata: "PVG", name: "Shanghai Pudong", city: "Shanghai", coordinate: .init(latitude: 31.1443, longitude: 121.8083)),
        Airport(iata: "PEK", name: "Beijing Capital", city: "Beijing", coordinate: .init(latitude: 40.0799, longitude: 116.6031)),
        Airport(iata: "CAN", name: "Guangzhou Baiyun", city: "Guangzhou", coordinate: .init(latitude: 23.3924, longitude: 113.2988)),
        Airport(iata: "SZX", name: "Shenzhen Bao'an", city: "Shenzhen", coordinate: .init(latitude: 22.6393, longitude: 113.8108)),
        // Japan / Korea
        Airport(iata: "NRT", name: "Narita", city: "Tokyo", coordinate: .init(latitude: 35.7647, longitude: 140.3864)),
        Airport(iata: "HND", name: "Haneda", city: "Tokyo", coordinate: .init(latitude: 35.5494, longitude: 139.7798)),
        Airport(iata: "KIX", name: "Kansai", city: "Osaka", coordinate: .init(latitude: 34.4347, longitude: 135.2440)),
        Airport(iata: "ICN", name: "Incheon", city: "Seoul", coordinate: .init(latitude: 37.4602, longitude: 126.4407)),
        Airport(iata: "GMP", name: "Gimpo", city: "Seoul", coordinate: .init(latitude: 37.5583, longitude: 126.7906)),
        // Middle East
        Airport(iata: "DXB", name: "Dubai Intl", city: "Dubai", coordinate: .init(latitude: 25.2532, longitude: 55.3657)),
        Airport(iata: "DOH", name: "Hamad Intl", city: "Doha", coordinate: .init(latitude: 25.2731, longitude: 51.6081)),
        Airport(iata: "AUH", name: "Zayed Intl", city: "Abu Dhabi", coordinate: .init(latitude: 24.4330, longitude: 54.6511)),
        Airport(iata: "JED", name: "King Abdulaziz", city: "Jeddah", coordinate: .init(latitude: 21.6796, longitude: 39.1565)),
        Airport(iata: "RUH", name: "King Khalid", city: "Riyadh", coordinate: .init(latitude: 24.9576, longitude: 46.6988)),
        Airport(iata: "IST", name: "Istanbul", city: "Istanbul", coordinate: .init(latitude: 41.2753, longitude: 28.7519)),
        // Europe
        Airport(iata: "LHR", name: "Heathrow", city: "London", coordinate: .init(latitude: 51.4700, longitude: -0.4543)),
        Airport(iata: "LGW", name: "Gatwick", city: "London", coordinate: .init(latitude: 51.1537, longitude: -0.1821)),
        Airport(iata: "CDG", name: "Charles de Gaulle", city: "Paris", coordinate: .init(latitude: 49.0097, longitude: 2.5479)),
        Airport(iata: "AMS", name: "Schiphol", city: "Amsterdam", coordinate: .init(latitude: 52.3105, longitude: 4.7683)),
        Airport(iata: "FRA", name: "Frankfurt", city: "Frankfurt", coordinate: .init(latitude: 50.0379, longitude: 8.5622)),
        Airport(iata: "MUC", name: "Munich", city: "Munich", coordinate: .init(latitude: 48.3538, longitude: 11.7861)),
        Airport(iata: "ZRH", name: "Zurich", city: "Zurich", coordinate: .init(latitude: 47.4647, longitude: 8.5492)),
        Airport(iata: "VIE", name: "Vienna", city: "Vienna", coordinate: .init(latitude: 48.1103, longitude: 16.5697)),
        Airport(iata: "MAD", name: "Madrid-Barajas", city: "Madrid", coordinate: .init(latitude: 40.4983, longitude: -3.5676)),
        Airport(iata: "BCN", name: "Barcelona-El Prat", city: "Barcelona", coordinate: .init(latitude: 41.2971, longitude: 2.0785)),
        Airport(iata: "FCO", name: "Fiumicino", city: "Rome", coordinate: .init(latitude: 41.8003, longitude: 12.2389)),
        Airport(iata: "MXP", name: "Malpensa", city: "Milan", coordinate: .init(latitude: 45.6306, longitude: 8.7281)),
        Airport(iata: "CPH", name: "Kastrup", city: "Copenhagen", coordinate: .init(latitude: 55.6180, longitude: 12.6508)),
        Airport(iata: "ARN", name: "Arlanda", city: "Stockholm", coordinate: .init(latitude: 59.6498, longitude: 17.9238)),
        Airport(iata: "HEL", name: "Helsinki-Vantaa", city: "Helsinki", coordinate: .init(latitude: 60.3183, longitude: 24.9497)),
        Airport(iata: "DUB", name: "Dublin", city: "Dublin", coordinate: .init(latitude: 53.4264, longitude: -6.2499)),
        // Oceania
        Airport(iata: "SYD", name: "Kingsford Smith", city: "Sydney", coordinate: .init(latitude: -33.9399, longitude: 151.1753)),
        Airport(iata: "MEL", name: "Tullamarine", city: "Melbourne", coordinate: .init(latitude: -37.6733, longitude: 144.8430)),
        Airport(iata: "BNE", name: "Brisbane", city: "Brisbane", coordinate: .init(latitude: -27.3842, longitude: 153.1175)),
        Airport(iata: "PER", name: "Perth", city: "Perth", coordinate: .init(latitude: -31.9403, longitude: 115.9672)),
        Airport(iata: "AKL", name: "Auckland", city: "Auckland", coordinate: .init(latitude: -37.0082, longitude: 174.7850)),
        // North America
        Airport(iata: "JFK", name: "John F. Kennedy", city: "New York", coordinate: .init(latitude: 40.6413, longitude: -73.7781)),
        Airport(iata: "EWR", name: "Newark Liberty", city: "Newark", coordinate: .init(latitude: 40.6895, longitude: -74.1745)),
        Airport(iata: "LAX", name: "Los Angeles Intl", city: "Los Angeles", coordinate: .init(latitude: 33.9416, longitude: -118.4085)),
        Airport(iata: "SFO", name: "San Francisco Intl", city: "San Francisco", coordinate: .init(latitude: 37.6213, longitude: -122.3790)),
        Airport(iata: "ORD", name: "O'Hare", city: "Chicago", coordinate: .init(latitude: 41.9742, longitude: -87.9073)),
        Airport(iata: "DFW", name: "Dallas-Fort Worth", city: "Dallas", coordinate: .init(latitude: 32.8998, longitude: -97.0403)),
        Airport(iata: "ATL", name: "Hartsfield-Jackson", city: "Atlanta", coordinate: .init(latitude: 33.6407, longitude: -84.4277)),
        Airport(iata: "YYZ", name: "Pearson", city: "Toronto", coordinate: .init(latitude: 43.6777, longitude: -79.6248)),
        Airport(iata: "YVR", name: "Vancouver Intl", city: "Vancouver", coordinate: .init(latitude: 49.1947, longitude: -123.1792)),
        Airport(iata: "MEX", name: "Benito Juárez", city: "Mexico City", coordinate: .init(latitude: 19.4361, longitude: -99.0719)),
    ]
}

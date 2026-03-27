//
//  Item.swift
//  BTCTicker
//
//  Created by hjl on 2026/3/27.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

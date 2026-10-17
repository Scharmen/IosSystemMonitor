//
//  Item.swift
//  SystemInfo
//
//  Created by Kevin Krämer on 10/16/26.
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
